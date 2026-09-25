using System.Reflection;
using FeeCalc.Api;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var version = Assembly.GetExecutingAssembly()
    .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "dev";

app.MapGet("/", () => Results.Text(
    $"FeeCalc API — phiên bản {version} — môi trường {app.Environment.EnvironmentName}\n" +
    "Thử: /api/fee?value=10000000&channel=Online"));

// Healthcheck: pipeline gọi sau khi deploy, không trả 200 thì rollback
app.MapGet("/health", () => Results.Ok(new { status = "ok", version }));

app.MapGet("/api/fee", (decimal value, Channel channel) =>
{
    try
    {
        var fee = FeeCalculator.Calculate(value, channel);
        return Results.Ok(new { value, channel = channel.ToString(), fee });
    }
    catch (ArgumentOutOfRangeException ex)
    {
        return Results.BadRequest(new { error = ex.Message });
    }
});

app.Run();
