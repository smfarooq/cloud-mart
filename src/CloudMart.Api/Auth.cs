using System.Security.Claims;
using System.Text.Encodings.Web;
using CloudMart.Core.Domain;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace CloudMart.Api;

public static class Policies
{
    public const string User = "CloudMart.User";
    public const string Admin = "CloudMart.Admin";

    /// <summary>The delegated scope the SPA requests (exposed by the API app registration).</summary>
    public const string ApiScope = "access_as_user";
}

public static class Roles
{
    /// <summary>An app role defined on the API app registration and assigned to users or groups.</summary>
    public const string Admin = "CloudMart.Admin";
}

public static class ClaimsPrincipalExtensions
{
    private static readonly string[] ScopeClaimTypes = ["scp", "http://schemas.microsoft.com/identity/claims/scope"];
    private const string ObjectIdClaimType = "http://schemas.microsoft.com/identity/claims/objectidentifier";

    public static bool HasScope(this ClaimsPrincipal user, string scope) =>
        user.Claims.Any(c => ScopeClaimTypes.Contains(c.Type) && c.Value.Split(' ').Contains(scope));

    /// <summary>The Entra object id (oid) is stable per user per tenant, so it is the customer key.</summary>
    public static Customer ToCustomer(this ClaimsPrincipal user) => new(
        user.FindFirstValue("oid") ?? user.FindFirstValue(ObjectIdClaimType) ?? user.FindFirstValue(ClaimTypes.NameIdentifier) ?? "anonymous",
        user.FindFirstValue("name") ?? user.Identity?.Name ?? "Unknown",
        user.IsInRole(Roles.Admin));
}

/// <summary>
/// Local development only: signs every request in as an admin. Program.cs refuses to start with this outside
/// Development unless Auth:AllowAnonymousDevMode is explicitly true.
/// </summary>
public sealed class DevAuthenticationHandler(
    IOptionsMonitor<AuthenticationSchemeOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder) : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    public const string SchemeName = "DevBypass";

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        var identity = new ClaimsIdentity(
            [new Claim("oid", "local-dev-user"), new Claim("name", "Local Developer"), new Claim("roles", Roles.Admin)],
            SchemeName,
            nameType: "name",
            roleType: "roles");
        return Task.FromResult(AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(identity), SchemeName)));
    }
}
