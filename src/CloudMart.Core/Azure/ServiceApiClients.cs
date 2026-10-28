using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Azure.Core;
using CloudMart.Core.Payments;
using CloudMart.Core.Shipping;

namespace CloudMart.Core.Azure;

/// <summary>
/// Service-to-service auth with no secret: the caller's managed identity gets a token for the target API's app
/// registration ("api://&lt;client-id&gt;/.default"). The target only accepts it if Entra put the right app role in it,
/// which happens because deploy/entra/setup-service-auth.sh assigned that role to this identity.
/// </summary>
public sealed class EntraTokenHandler(TokenCredential credential, string scope) : DelegatingHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        // The credential caches the token until shortly before it expires, so this is not a round trip per call.
        var token = await credential.GetTokenAsync(new TokenRequestContext([scope]), cancellationToken);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        return await base.SendAsync(request, cancellationToken);
    }
}

/// <summary>
/// Calls the Payments API. The HttpClient carries the standard resilience pipeline (timeouts, retries with jitter,
/// circuit breaker), so a POST can be retried: safe only because every attempt sends the same Idempotency-Key.
/// </summary>
public sealed class PaymentsApiClient(HttpClient http) : IPaymentGateway, IHealthProbe
{
    public string Name => "payments-api";

    public async Task<Payment> ChargeAsync(ChargeRequest request, CancellationToken ct = default)
    {
        using var message = new HttpRequestMessage(HttpMethod.Post, "payments")
        {
            Content = JsonContent.Create(request, options: CloudMartJson.Options),
        };
        message.Headers.Add("Idempotency-Key", request.IdempotencyKey);
        using var response = await http.SendAsync(message, ct);
        return await ServiceResponse.ReadAsync<Payment>(response, ct);
    }

    public async Task<Payment> RefundAsync(string paymentId, string reason, CancellationToken ct = default)
    {
        using var response = await http.PostAsJsonAsync($"payments/{Uri.EscapeDataString(paymentId)}/refund", new RefundRequest(reason), CloudMartJson.Options, ct);
        return await ServiceResponse.ReadAsync<Payment>(response, ct);
    }

    public async Task CheckAsync(CancellationToken ct)
    {
        using var response = await http.GetAsync("health/ready", ct);
        response.EnsureSuccessStatusCode();
    }
}

/// <summary>Calls the Shipping API. PUT /shipments/{orderId} is idempotent by definition: same URL, same result.</summary>
public sealed class ShippingApiClient(HttpClient http) : IShippingGateway, IHealthProbe
{
    public string Name => "shipping-api";

    public async Task<ShipmentResult> ScheduleAsync(Guid orderId, ShipmentRequest request, CancellationToken ct = default)
    {
        using var response = await http.PutAsJsonAsync($"shipments/{orderId}", request, CloudMartJson.Options, ct);
        if (response.StatusCode == HttpStatusCode.UnprocessableEntity)
        {
            // 422 = understood, but the business rules say no. Not retried, not an exception.
            var problem = await response.Content.ReadFromJsonAsync<ServiceProblem>(CloudMartJson.Options, ct);
            return new ShipmentResult(null, problem?.Detail ?? "the shipping service rejected the order");
        }
        return new ShipmentResult(await ServiceResponse.ReadAsync<Shipment>(response, ct), null);
    }

    public async Task CancelAsync(Guid orderId, string reason, CancellationToken ct = default)
    {
        using var response = await http.PostAsJsonAsync($"shipments/{orderId}/cancel", new CancelShipmentRequest(reason), CloudMartJson.Options, ct);
        await ServiceResponse.ReadAsync<Shipment>(response, ct);
    }

    public async Task CheckAsync(CancellationToken ct)
    {
        using var response = await http.GetAsync("health/ready", ct);
        response.EnsureSuccessStatusCode();
    }
}

/// <summary>The fields CloudMart reads from an RFC 9457 problem details response.</summary>
internal sealed record ServiceProblem(string? Title, string? Detail);

internal static class ServiceResponse
{
    public static async Task<T> ReadAsync<T>(HttpResponseMessage response, CancellationToken ct)
    {
        if (!response.IsSuccessStatusCode)
        {
            // Surface the service's own explanation (problem details) instead of a bare status code.
            var body = await response.Content.ReadAsStringAsync(ct);
            throw new HttpRequestException(
                $"{(int)response.StatusCode} {response.ReasonPhrase} from {response.RequestMessage?.RequestUri}: {body[..Math.Min(body.Length, 300)]}",
                null,
                response.StatusCode);
        }
        return await response.Content.ReadFromJsonAsync<T>(CloudMartJson.Options, ct)
            ?? throw new InvalidOperationException($"Empty response from {response.RequestMessage?.RequestUri}.");
    }
}
