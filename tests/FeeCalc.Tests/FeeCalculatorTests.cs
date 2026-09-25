using FeeCalc.Api;

namespace FeeCalc.Tests;

public class FeeCalculatorTests
{
    [Fact]
    public void Counter_order_uses_counter_rate()
    {
        Assert.Equal(25_000m, FeeCalculator.Calculate(10_000_000m, Channel.Counter));
    }

    [Fact]
    public void Fee_is_rounded_to_whole_dong()
    {
        // 1.234.567 x 0,25% = 3.086,4175 -> 3.086
        Assert.Equal(3_086m, FeeCalculator.Calculate(1_234_567m, Channel.Counter));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public void Non_positive_order_value_is_rejected(decimal value)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => FeeCalculator.Calculate(value, Channel.Counter));
    }
}
