namespace Weather.Contracts;

public sealed record WeatherResponse(
    string Location,
    string LocalTime,
    double TemperatureF,
    double FeelsLikeF,
    string Condition,
    int HumidityPercent,
    double WindMph
);
