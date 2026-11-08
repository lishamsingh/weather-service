using System.Net.Http.Headers;
using System.Net.Http.Json;
using Azure.Identity;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Weather.Contracts;

var host = Host.CreateApplicationBuilder(args);
host.Environment.ContentRootPath = AppContext.BaseDirectory;

using var app = host.Build();

var config = app.Services.GetRequiredService<IConfiguration>();
var logger = app.Services.GetRequiredService<ILogger<Program>>();

// --- 1. Time-gate: only run at 7 AM Central (Mon–Fri) ---
var skipTimeCheck = config.GetValue<bool>("Job:SkipTimeCheck");
if (!skipTimeCheck)
{
    var central = TimeZoneInfo.FindSystemTimeZoneById("America/Chicago");
    var now = TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, central);
    if (now.Hour != 7)
    {
        logger.LogInformation("Time check skipped: Central time is {Time}. Expected 7 AM.", now.ToString("HH:mm"));
        return 0;
    }
}

// --- 2. Build HTTP client ---
using var http = new HttpClient();

var bypassAuth = config.GetValue<bool>("Job:BypassAuth");
if (!bypassAuth)
{
    var scope = config["AzureAd:Scope"]
        ?? throw new InvalidOperationException("AzureAd:Scope is not configured.");

    var credential = new DefaultAzureCredential();
    var tokenResult = await credential.GetTokenAsync(
        new Azure.Core.TokenRequestContext([scope]));

    http.DefaultRequestHeaders.Authorization =
        new AuthenticationHeaderValue("Bearer", tokenResult.Token);
}

// --- 3. Call scheduled endpoint with retry ---
var url = config["WeatherApi__ScheduledUrl"]
    ?? throw new InvalidOperationException("WeatherApi__ScheduledUrl is not configured.");

const int maxAttempts = 3;
WeatherResponse? weather = null;

for (int attempt = 1; attempt <= maxAttempts; attempt++)
{
    try
    {
        var response = await http.PostAsync(url, content: null);
        response.EnsureSuccessStatusCode();
        weather = await response.Content.ReadFromJsonAsync<WeatherResponse>();
        break;
    }
    catch (HttpRequestException ex)
    {
        logger.LogWarning(ex, "Attempt {Attempt}/{Max} failed.", attempt, maxAttempts);
        if (attempt == maxAttempts)
        {
            logger.LogError("All {Max} attempts failed. Exiting.", maxAttempts);
            return 1;
        }
        await Task.Delay(TimeSpan.FromSeconds(Math.Pow(2, attempt)));
    }
}

// --- 4. Log structured result ---
logger.LogInformation(
    "Daily weather | Location: {Location} | Local time: {LocalTime} | " +
    "Temp: {TempF}°F (feels {FeelsLikeF}°F) | {Condition} | " +
    "Humidity: {Humidity}% | Wind: {WindMph} mph",
    weather!.Location, weather.LocalTime,
    weather.TemperatureF, weather.FeelsLikeF,
    weather.Condition, weather.HumidityPercent, weather.WindMph);

return 0;
