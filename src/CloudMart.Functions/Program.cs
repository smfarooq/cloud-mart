using Azure.Core.Serialization;
using CloudMart.Core;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

builder.Services
    .AddApplicationInsightsTelemetryWorkerService()
    .ConfigureFunctionsApplicationInsights();

// Same JSON shape as the APIs (camelCase, enums as names). Durable Functions stores saga inputs and outputs with
// this serializer, so its history in the task hub tables reads "status": "Captured" rather than "Status": 0.
builder.Services.Configure<WorkerOptions>(options => options.Serializer = new JsonObjectSerializer(CloudMartJson.Options));

// Same services as the API. The Functions host owns the triggers, so no in-process worker is registered here.
builder.Services.AddCloudMartCore(builder.Configuration, CloudMartHost.Functions);

builder.Build().Run();
