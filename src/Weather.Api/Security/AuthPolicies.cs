namespace Weather.Api.Security;

public static class AuthPolicies
{
    /// <summary>Entra app role held by the daily job's managed identity.</summary>
    public const string JobExecute = "JobExecute";
}
