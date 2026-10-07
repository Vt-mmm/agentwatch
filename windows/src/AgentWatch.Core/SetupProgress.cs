namespace AgentWatch;

// Navigation depends on verified prerequisites, never on a button label or an
// old success message. Changing a credential/distribution invalidates later work.
public sealed class SetupProgress
{
    public int Step { get; private set; }
    public bool CredentialsVerified { get; private set; }
    public bool RuntimeVerified { get; private set; }
    public bool Applied { get; private set; }
    public bool CanAdvance => Step switch { 0 => true, 1 => CredentialsVerified, 2 => RuntimeVerified, _ => false };
    public void CredentialsChanged() { CredentialsVerified = RuntimeVerified = Applied = false; Step = Math.Min(Step, 1); }
    public void RuntimeChanged() { RuntimeVerified = Applied = false; Step = Math.Min(Step, 2); }
    public void VerifyCredentials() { CredentialsVerified = true; }
    public void VerifyRuntime() { if (!CredentialsVerified) throw new InvalidOperationException("Verify credentials first."); RuntimeVerified = true; }
    public void Advance() { if (!CanAdvance) throw new InvalidOperationException("Complete the current step first."); Step++; }
    public void Back() { Step = Math.Max(0, Step - 1); }
    public void Complete() { if (Step != 3 || !CredentialsVerified || !RuntimeVerified) throw new InvalidOperationException("Setup is incomplete."); Applied = true; }
    public void Reset() { Step = 0; CredentialsVerified = RuntimeVerified = Applied = false; }
}
