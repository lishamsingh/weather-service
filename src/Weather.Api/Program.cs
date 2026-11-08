using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Identity.Web;
using Weather.Api;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddHttpClient<IWeatherProvider, WeatherApiProvider>();

// In Development with Auth:BypassJobRole=true we skip Entra entirely so the
// app starts without a ClientId configured in appsettings.
var bypassJobRole = builder.Environment.IsDevelopment() &&
                    builder.Configuration.GetValue<bool>("Auth:BypassJobRole");

if (!bypassJobRole)
{
    builder.Services
        .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
        .AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("AzureAd"));

    builder.Services.AddAuthorization(options =>
        options.AddPolicy("JobExecute", policy =>
            policy.RequireClaim("roles", "JobExecute")));
}

if (builder.Environment.IsDevelopment())
    builder.Services.AddOpenApi();

var app = builder.Build();

if (app.Environment.IsDevelopment())
    app.MapOpenApi();

if (!bypassJobRole)
{
    app.UseAuthentication();
    app.UseAuthorization();
}

app.MapGet("/health", () => Results.Ok());

app.MapGet("/api/weather/{zipCode}", async (
    string zipCode,
    IWeatherProvider provider,
    HttpContext context,
    IConfiguration config) =>
{
    var key = context.Request.Headers["X-Api-Key"].FirstOrDefault();
    if (string.IsNullOrEmpty(key) || key != config["ApiKey"])
        return Results.Unauthorized();

    var result = await provider.GetWeatherAsync(zipCode, context.RequestAborted);
    return result is null ? Results.NotFound() : Results.Ok(result);
});

var scheduled = app.MapPost("/api/weather/scheduled", async (
    IWeatherProvider provider,
    IConfiguration config,
    CancellationToken ct) =>
{
    var zipCode = config["WeatherApi__ZipCode"] ?? "10001";
    var result = await provider.GetWeatherAsync(zipCode, ct);
    return result is null ? Results.NotFound() : Results.Ok(result);
});

if (!bypassJobRole)
    scheduled.RequireAuthorization("JobExecute");

app.Run();

// Needed for WebApplicationFactory in tests
public partial class Program { }
