using Azure.Messaging.ServiceBus;
using CloudMart.Core;
using CloudMart.Core.Domain;
using CloudMart.Core.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace CloudMart.Functions;

/// <summary>
/// Three independent consumers of the "orders" topic, one per subscription (infra/modules/servicebus.bicep).
/// "ServiceBus" is an identity-based connection: app settings ServiceBus__fullyQualifiedNamespace,
/// ServiceBus__credential=managedidentity and ServiceBus__clientId. No connection string.
/// </summary>
public sealed class OrderFunctions(OrderFulfillmentService fulfillment, ILogger<OrderFunctions> logger)
{
    /// <summary>
    /// Exceptions abandon the message; Service Bus redelivers it until maxDeliveryCount (3) and then moves it
    /// to the dead-letter queue. Tick "simulate failure" at checkout to watch that happen.
    /// </summary>
    [Function(nameof(FulfillOrder))]
    public async Task FulfillOrder(
        [ServiceBusTrigger("orders", "fulfillment", Connection = "ServiceBus")] ServiceBusReceivedMessage message,
        CancellationToken ct)
    {
        var evt = Read(message);
        logger.LogInformation("Fulfilling order {OrderId}, delivery attempt {DeliveryCount}", evt.OrderId, message.DeliveryCount);
        await fulfillment.ProcessAsync(evt, ct);
    }

    /// <summary>Only receives messages matching the subscription's SQL filter: total > 500.</summary>
    [Function(nameof(FlagHighValueOrder))]
    public Task FlagHighValueOrder(
        [ServiceBusTrigger("orders", "high-value", Connection = "ServiceBus")] ServiceBusReceivedMessage message,
        CancellationToken ct) =>
        fulfillment.FlagHighValueAsync(Read(message), ct);

    [Function(nameof(NotifyCustomer))]
    public void NotifyCustomer(
        [ServiceBusTrigger("orders", "notifications", Connection = "ServiceBus")] ServiceBusReceivedMessage message) =>
        fulfillment.Notify(Read(message));

    private static OrderPlaced Read(ServiceBusReceivedMessage message) =>
        message.Body.ToObjectFromJson<OrderPlaced>(CloudMartJson.Options)
        ?? throw new InvalidOperationException($"Message {message.MessageId} has an empty body.");
}
