using CloudMart.Core.Payments;
using CloudMart.Core.Shipping;

namespace CloudMart.Core.InProcess;

/// <summary>The payments module called directly, before it is extracted into the Payments API (phase 16).</summary>
public sealed class InProcessPaymentGateway(PaymentProcessor processor) : IPaymentGateway
{
    public async Task<Payment> ChargeAsync(ChargeRequest request, CancellationToken ct = default) =>
        (await processor.ChargeAsync(request, request.IdempotencyKey, ct)).Payment;

    public async Task<Payment> RefundAsync(string paymentId, string reason, CancellationToken ct = default) =>
        await processor.RefundAsync(paymentId, reason, ct)
        ?? throw new InvalidOperationException($"Payment {paymentId} was not found.");
}

/// <summary>The shipping module called directly, before it is extracted into the Shipping API (phase 16).</summary>
public sealed class InProcessShippingGateway(ShippingProcessor processor) : IShippingGateway
{
    public async Task<ShipmentResult> ScheduleAsync(Guid orderId, ShipmentRequest request, CancellationToken ct = default) =>
        (await processor.ScheduleAsync(orderId, request, ct)).Result;

    public Task CancelAsync(Guid orderId, string reason, CancellationToken ct = default) =>
        processor.CancelAsync(orderId, reason, ct);
}
