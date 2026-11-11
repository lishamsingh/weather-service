using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Identity.Web;
using Weather.Api;
using Weather.Api.Security;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddHttpClient<IWeatherProvider, WeatherApiProvider>();
builder.Services.AddControllers();

// In Development with Auth:BypassJobRole=true we skip Entra entirely so the
// app starts without a ClientId configured in appsettings.
var bypassJobRole = builder.Environment.IsDevelopment() &&
                    builder.Configuration.GetValue<bool>("Auth:BypassJobRole");

if (bypassJobRole)
{
    builder.Services.AddAuthorization(options =>
        options.AddPolicy(AuthPolicies.JobExecute, policy => policy.RequireAssertion(_ => true)));
}
else
{
    builder.Services
        .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
        .AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("AzureAd"));

    builder.Services.AddAuthorization(options =>
        options.AddPolicy(AuthPolicies.JobExecute, policy =>
            // RequireRole (not RequireClaim("roles")): the JWT handler may map the token's
            // "roles" claim to ClaimTypes.Role, and IsInRole checks whichever type is configured.
            policy.RequireRole(AuthPolicies.JobExecute)));
}

if (builder.Environment.IsDevelopment())
    builder.Services.AddOpenApi();

var app = builder.Build();

if (app.Environment.IsDevelopment())
    app.MapOpenApi();

if (!bypassJobRole)
    app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/health", () => Results.Ok());
app.MapControllers();

app.Run();

// Needed for WebApplicationFactory in tests
public partial class Program { }
