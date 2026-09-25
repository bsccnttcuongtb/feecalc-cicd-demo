namespace FeeCalc.Api;

public enum Channel
{
    Counter, // đặt lệnh tại quầy
    Online   // đặt lệnh qua Webtrade / Mobile
}

public static class FeeCalculator
{
    public const decimal CounterRate = 0.0025m; // 0,25%
    public const decimal OnlineRate = 0.0015m;  // 0,15% — ưu đãi kênh online

    /// <summary>Phí giao dịch (VND) cho một lệnh có giá trị <paramref name="orderValue"/>.</summary>
    public static decimal Calculate(decimal orderValue, Channel channel)
    {
        if (orderValue <= 0)
            throw new ArgumentOutOfRangeException(nameof(orderValue), "Giá trị lệnh phải > 0");

        var rate = CounterRate;
        return Math.Round(orderValue * rate, 0, MidpointRounding.AwayFromZero);
    }
}
