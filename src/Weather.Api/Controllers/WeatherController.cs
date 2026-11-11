using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Weather.Api.Security;
using Weather.Contracts;

namespace Weather.Api.Controllers;

/// <summary>Current weather for US zip codes, from WeatherAPI.com.</summary>
[ApiController]
[Route("api/weather")]
[Produces("application/json")]
public sealed class WeatherController(IWeatherProvider provider, IConfiguration config) : ControllerBase
{
    /// <summary>Manual lookup: today's weather for any 5-digit US zip. Requires the X-Api-Key header.</summary>
    [HttpGet("{zipCode:regex(^\\d{{5}}$)}")]
    [RequireApiKey]
    [ProducesResponseType<WeatherResponse>(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status401Unauthorized)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<WeatherResponse>> GetByZipCode(string zipCode, CancellationToken ct)
    {
        var result = await provider.GetWeatherAsync(zipCode, ct);
        return result is null ? NotFound() : Ok(result);
    }

    /// <summary>Scheduled lookup for the configured zip. Called by the daily job; requires the JobExecute role.</summary>
    [HttpPost("scheduled")]
    [Authorize(Policy = AuthPolicies.JobExecute)]
    [ProducesResponseType<WeatherResponse>(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status401Unauthorized)]
    [ProducesResponseType(StatusCodes.Status403Forbidden)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<WeatherResponse>> GetScheduled(CancellationToken ct)
    {
        var zipCode = config["WeatherApi:ZipCode"] ?? "10001";
        var result = await provider.GetWeatherAsync(zipCode, ct);
        return result is null ? NotFound() : Ok(result);
    }
}
