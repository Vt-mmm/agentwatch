using AgentWatch;
using Xunit;

namespace AgentWatch.Tests;

public class ReleaseCheckTests
{
    const string Props = "<Project><PropertyGroup><Nullable>enable</Nullable><Version>0.1.7</Version></PropertyGroup></Project>";

    [Fact]
    public void ReadsTheVersionTheInstallerInstalls() => Assert.Equal(new Version(0, 1, 7), ReleaseCheck.Parse(Props));

    [Theory]
    [InlineData("<Project><PropertyGroup><Version>0.1.7-beta</Version></PropertyGroup></Project>")]
    [InlineData("<Project><PropertyGroup><Version>1.2</Version></PropertyGroup></Project>")]
    [InlineData("<Project><PropertyGroup></PropertyGroup></Project>")]
    [InlineData("not xml")]
    public void IgnoresAnythingButAPlainVersion(string props) => Assert.Null(ReleaseCheck.Parse(props));

    [Fact]
    public void OffersOnlyANewerRelease()
    {
        Assert.Equal(new Version(0, 1, 7), ReleaseCheck.Newer(new Version(0, 1, 7), new Version(0, 1, 6)));
        Assert.Null(ReleaseCheck.Newer(new Version(0, 1, 6), new Version(0, 1, 6)));
        Assert.Null(ReleaseCheck.Newer(new Version(0, 1, 5), new Version(0, 1, 6)));
        Assert.Null(ReleaseCheck.Newer(null, new Version(0, 1, 6)));
    }

    [Fact]
    public void UpdaterRunsTheInstallerAndKeepsAFailureOnScreen()
    {
        // The dialog passes it inside -Command "..." to powershell.exe.
        Assert.DoesNotContain('"', ReleaseCheck.UpdaterCommand);
        Assert.Contains(ReleaseCheck.InstallCommand, ReleaseCheck.UpdaterCommand);
        Assert.Contains("Read-Host", ReleaseCheck.UpdaterCommand);
    }

    [Fact]
    public void ChecksEveryHour() => Assert.Equal(TimeSpan.FromHours(1), ReleaseCheck.Every);
}
