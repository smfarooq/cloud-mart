using CloudMart.Core.Domain;
using CloudMart.Core.Payments;
using CloudMart.Core.Services;
using CloudMart.Core.Shipping;
using Microsoft.Azure.Functions.Worker;
using Microsoft.DurableTask;

namespace CloudMart.Functions;

/// <summary>
/// The order saga as a Durable Functions orchestration (phase 16). The orchestrator is <see cref="OrderSaga"/>
/// itself; each step is an activity function. Durable Functions records every step's result in the task hub
/// (tables and queues in the storage account), so after a crash, scale-in or redeploy the saga resumes where it
/// stopped. It never re-runs a step that already completed, which is how it avoids charging a customer twice.
/// </summary>
public sealed class OrderSagaFunctions(OrderSagaActivities activities)
{
    public const string Orchestrator = "OrderSaga";

    [Function(Orchestrator)]
    public static Task<OrderOutcome?> RunOrderSaga([OrchestrationTrigger] TaskOrchestrationContext context) =>
        OrderSaga.RunAsync(new DurableOrderSagaContext(context), context.GetInput<OrderPlaced>()!);

    [Function(nameof(PrepareOrder))]
    public Task<OrderCheck> PrepareOrder([ActivityTrigger] OrderPlaced order, FunctionContext context) =>
        activities.PrepareAsync(order, context.CancellationToken);

    [Function(nameof(ChargePayment))]
    public Task<Payment> ChargePayment([ActivityTrigger] OrderPlaced order, FunctionContext context) =>
        activities.ChargeAsync(order, context.CancellationToken);

    [Function(nameof(ScheduleShipment))]
    public Task<ShipmentResult> ScheduleShipment([ActivityTrigger] OrderPlaced order, FunctionContext context) =>
        activities.ShipAsync(order, context.CancellationToken);

    [Function(nameof(RefundPayment))]
    public Task<Payment> RefundPayment([ActivityTrigger] RefundCommand command, FunctionContext context) =>
        activities.RefundAsync(command, context.CancellationToken);

    [Function(nameof(CompleteOrder))]
    public Task<bool> CompleteOrder([ActivityTrigger] OrderCompletion completion, FunctionContext context) =>
        activities.CompleteAsync(completion, context.CancellationToken);
}

/// <summary>Maps each saga step to an activity call with its own retry policy.</summary>
internal sealed class DurableOrderSagaContext(TaskOrchestrationContext context) : IOrderSagaContext
{
    // 3 attempts per step, 5 s then 10 s apart. These retries are durable: they survive the app restarting, unlike
    // the HTTP client's in-memory retries (which still run first, inside each attempt).
    private static readonly TaskOptions Retry = TaskOptions.FromRetryPolicy(
        new RetryPolicy(maxNumberOfAttempts: 3, firstRetryInterval: TimeSpan.FromSeconds(5), backoffCoefficient: 2));

    public Task<OrderCheck> PrepareAsync(OrderPlaced order) =>
        context.CallActivityAsync<OrderCheck>(nameof(OrderSagaFunctions.PrepareOrder), order, Retry);

    public Task<Payment> ChargeAsync(OrderPlaced order) =>
        context.CallActivityAsync<Payment>(nameof(OrderSagaFunctions.ChargePayment), order, Retry);

    public Task<ShipmentResult> ShipAsync(OrderPlaced order) =>
        context.CallActivityAsync<ShipmentResult>(nameof(OrderSagaFunctions.ScheduleShipment), order, Retry);

    public Task<Payment> RefundAsync(RefundCommand command) =>
        context.CallActivityAsync<Payment>(nameof(OrderSagaFunctions.RefundPayment), command, Retry);

    public Task<bool> CompleteAsync(OrderCompletion completion) =>
        context.CallActivityAsync<bool>(nameof(OrderSagaFunctions.CompleteOrder), completion, Retry);
}
