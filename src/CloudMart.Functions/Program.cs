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

// Same services as the API. The Functions host owns the triggers, so no in-process worker is registered here.
builder.Services.AddCloudMartCore(builder.Configuration, CloudMartHost.Functions);

builder.Build().Run();
