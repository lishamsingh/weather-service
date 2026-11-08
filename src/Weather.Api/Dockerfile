# syntax=docker/dockerfile:1
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /repo

# Restore as a separate layer — only re-runs when project files change
COPY global.json Directory.Build.props ./
COPY src/Weather.Contracts/Weather.Contracts.csproj src/Weather.Contracts/
COPY src/Weather.Api/Weather.Api.csproj              src/Weather.Api/
COPY src/Weather.Job/Weather.Job.csproj              src/Weather.Job/
COPY tests/Weather.Api.Tests/Weather.Api.Tests.csproj tests/Weather.Api.Tests/
COPY tests/Weather.Job.Tests/Weather.Job.Tests.csproj tests/Weather.Job.Tests/
RUN dotnet restore src/Weather.Api/Weather.Api.csproj

COPY . .
RUN dotnet publish src/Weather.Api/Weather.Api.csproj \
    -c Release --no-restore -o /app

# ---
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

# Use the built-in non-root user included in .NET images
USER app

COPY --from=build --chown=app /app .
ENTRYPOINT ["dotnet", "Weather.Api.dll"]
