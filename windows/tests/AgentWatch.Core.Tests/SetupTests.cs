using System.Text.Json;
using AgentWatch;
using Xunit;

namespace AgentWatch.Tests;

public class SetupProgressTests
{
    [Fact]
    public void WizardRequiresVerifiedPrerequisitesAndAnExplicitApply()
    {
        var flow = new SetupProgress();
        Assert.Throws<InvalidOperationException>(flow.VerifyRuntime);
        flow.Advance();
        Assert.Equal(1, flow.Step);
        Assert.Throws<InvalidOperationException>(flow.Advance);
        flow.VerifyCredentials(); flow.Advance();
        Assert.Throws<InvalidOperationException>(flow.Advance);
        flow.VerifyRuntime(); flow.Advance();
        Assert.False(flow.Applied);
        flow.Complete(); Assert.True(flow.Applied);
    }

    [Fact]
    public void EditingAKeyOrDistributionInvalidatesLaterChecks()
    {
        var flow = new SetupProgress(); flow.Advance(); flow.VerifyCredentials(); flow.Advance(); flow.VerifyRuntime(); flow.Advance();
        flow.RuntimeChanged();
        Assert.Equal(2, flow.Step); Assert.True(flow.CredentialsVerified); Assert.False(flow.RuntimeVerified);
        Assert.Throws<InvalidOperationException>(flow.Complete);
        flow.CredentialsChanged();
        Assert.Equal(1, flow.Step); Assert.False(flow.CredentialsVerified);
        flow.Back(); Assert.Equal(0, flow.Step);
    }
}

public class SetupConnectionTests
{
    sealed class MemoryKeys : IStudioKeyStore
    {
        public readonly Dictionary<string, string> Values = [];
        public string? Load(string id) => Values.GetValueOrDefault(id);
        public void Save(string id, string key) => Values[id] = key;
        public void Delete(string id) => Values.Remove(id);
    }

    [Fact]
    public async Task VerifyingAKeyDoesNotPersistIt()
    {
        var directory = Directory.CreateTempSubdirectory("agentwatch-preview-").FullName;
        try
        {
            var profiles = new StudioProfileStore(directory); var keys = new MemoryKeys();
            var connector = new StudioConnector(profiles, keys, new StudioClient(new FakeStudio()));
            var code = "https://studio.example.com#as_live_test-key_0123456789";
            var preview = await connector.VerifyAsync(code);
            Assert.Equal(StudioCredentialMode.managed, preview.Profile.CredentialMode);
            Assert.Empty(keys.Values); Assert.Empty(profiles.Profiles());
            await connector.ConnectAsync(code);
            Assert.Single(keys.Values); Assert.NotNull(profiles.Active());
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task FailedProfileSaveRestoresTheExistingKey()
    {
        var directory = Directory.CreateTempSubdirectory("agentwatch-save-").FullName;
        try
        {
            var profiles = new StudioProfileStore(directory); var keys = new MemoryKeys();
            var studio = new FakeStudio();
            var connector = new StudioConnector(profiles, keys, new StudioClient(studio));
            var original = "https://studio.example.com#as_live_original_0123456789";
            var (profile, _) = await connector.ConnectAsync(original);
            // A directory at the temporary filename makes the profile write fail
            // after credential verification and key replacement.
            Directory.CreateDirectory(Path.Combine(directory, "profiles.json." + Environment.ProcessId + ".tmp"));
            var error = await Record.ExceptionAsync(async () => await connector.ConnectAsync("https://studio.example.com#as_live_replacement_0123456789"));
            Assert.True(error is IOException or UnauthorizedAccessException);
            Assert.Equal("as_live_original_0123456789", keys.Load(profile.Id));
        }
        finally { Directory.Delete(directory, true); }
    }
}

public class WslReadinessTests
{
    sealed class Wsl(bool fails = false) : IWsl
    {
        public readonly List<string[]> Commands = [];
        public Task<string> RunAsync(string? distro, string? input, params string[] command)
        {
            Commands.Add(command);
            if (command[0] == "bash" && fails) throw new InvalidOperationException("wsl-command-failed");
            return new FakeWsl().RunAsync(distro, input, command);
        }
    }
    [Fact]
    public async Task ResolvesDefaultAndRequiresSandboxInteropAndUserRuntime()
    {
        var wsl = new Wsl(); var result = await WslReadiness.CheckAsync(wsl, " ");
        Assert.Equal("Ubuntu", result.Distro);
        Assert.Contains("bwrap --unshare-user", wsl.Commands.Last().Last());
        Assert.Contains("WSLInterop", wsl.Commands.Last().Last());
        Assert.DoesNotContain("sudo", wsl.Commands.Last().Last());
        Assert.DoesNotContain(wsl.Commands, command => command.Any(part => part.Contains('\r')));
        await Assert.ThrowsAsync<InvalidOperationException>(() => WslReadiness.CheckAsync(new Wsl(true), "Ubuntu"));
    }
}
