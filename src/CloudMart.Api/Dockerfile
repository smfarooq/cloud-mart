# Build context is the repository root:
#   docker build -f src/CloudMart.Api/Dockerfile -t cloudmart-api .
#   az acr build -r <registry> -f src/CloudMart.Api/Dockerfile -t cloudmart-api:{{.Run.ID}} .
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY src/CloudMart.Core/CloudMart.Core.csproj src/CloudMart.Core/
COPY src/CloudMart.ServiceDefaults/CloudMart.ServiceDefaults.csproj src/CloudMart.ServiceDefaults/
COPY src/CloudMart.Api/CloudMart.Api.csproj src/CloudMart.Api/
RUN dotnet restore src/CloudMart.Api/CloudMart.Api.csproj
COPY src/CloudMart.Core/ src/CloudMart.Core/
COPY src/CloudMart.ServiceDefaults/ src/CloudMart.ServiceDefaults/
COPY src/CloudMart.Api/ src/CloudMart.Api/
RUN dotnet publish src/CloudMart.Api/CloudMart.Api.csproj -c Release -o /app --no-restore

# Chiseled = distroless Ubuntu: no shell, no package manager, runs as a non-root user.
# "-extra" adds ICU and tzdata, which Microsoft.Data.SqlClient needs.
FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled-extra AS runtime
WORKDIR /app
COPY --from=build /app .
EXPOSE 8080
ENTRYPOINT ["dotnet", "CloudMart.Api.dll"]
