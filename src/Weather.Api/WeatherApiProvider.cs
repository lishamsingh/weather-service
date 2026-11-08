using System.Net.Http.Json;
using System.Text.Json.Serialization;
using Weather.Contracts;

namespace Weather.Api;

public sealed class WeatherApiProvider : IWeatherProvider
{
    private readonly HttpClient _http;
    private readonly string _apiKey;

    public WeatherApiProvider(HttpClient http, IConfiguration config)
    {
        _http = http;
        _apiKey = config["WeatherApi__Key"] ?? throw new InvalidOperationException("WeatherApi__Key is not configured.");
    }

    public async Task<WeatherResponse?> GetWeatherAsync(string zipCode, CancellationToken cancellationToken = default)
    {
        var url = $"https://api.weatherapi.com/v1/current.json?key={_apiKey}&q={Uri.EscapeDataString(zipCode)}&aqi=no";

        var response = await _http.GetAsync(url, cancellationToken);

        if (!response.IsSuccessStatusCode)
            return null;

        var root = await response.Content.ReadFromJsonAsync<WeatherApiRoot>(cancellationToken);

        if (root is null)
            return null;

        return new WeatherResponse(
            Location: root.Location.Name,
            LocalTime: root.Location.Localtime,
            TemperatureF: root.Current.TempF,
            FeelsLikeF: root.Current.FeelslikeF,
            Condition: root.Current.Condition.Text,
            HumidityPercent: root.Current.Humidity,
            WindMph: root.Current.WindMph
        );
    }

    // Internal deserialization types — not part of the public contract
    private sealed record WeatherApiRoot(
        [property: JsonPropertyName("location")] WeatherApiLocation Location,
        [property: JsonPropertyName("current")]  WeatherApiCurrent  Current
    );

    private sealed record WeatherApiLocation(
        [property: JsonPropertyName("name")]      string Name,
        [property: JsonPropertyName("localtime")] string Localtime
    );

    private sealed record WeatherApiCurrent(
        [property: JsonPropertyName("temp_f")]      double TempF,
        [property: JsonPropertyName("feelslike_f")] double FeelslikeF,
        [property: JsonPropertyName("condition")]   WeatherApiCondition Condition,
        [property: JsonPropertyName("humidity")]    int    Humidity,
        [property: JsonPropertyName("wind_mph")]    double WindMph
    );

    private sealed record WeatherApiCondition(
        [property: JsonPropertyName("text")] string Text
    );
}
