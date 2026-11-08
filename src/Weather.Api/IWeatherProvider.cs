using Weather.Contracts;

namespace Weather.Api;

public interface IWeatherProvider
{
    Task<WeatherResponse?> GetWeatherAsync(string zipCode, CancellationToken cancellationToken = default);
}
