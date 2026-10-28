using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace CloudMart.ServiceDefaults;

public sealed class DevAuthenticationOptions : AuthenticationSchemeOptions
{
    /// <summary>App roles the fake caller gets, so role-protected endpoints work before Entra ID is set up.</summary>
    public string[] Roles { get; set; } = [];
}

/// <summary>
/// Local development only: signs every request in. The hosts refuse to start with this outside Development unless
/// Auth:AllowAnonymousDevMode is explicitly true.
/// </summary>
public sealed class DevAuthenticationHandler(
    IOptionsMonitor<DevAuthenticationOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder) : AuthenticationHandler<DevAuthenticationOptions>(options, logger, encoder)
{
    public const string SchemeName = "DevBypass";

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        var identity = new ClaimsIdentity(
            [
                new Claim("oid", "local-dev-user"),
                new Claim("name", "Local Developer"),
                .. Options.Roles.Select(role => new Claim("roles", role)),
            ],
            SchemeName,
            nameType: "name",
            roleType: "roles");
        return Task.FromResult(AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(identity), SchemeName)));
    }
}
