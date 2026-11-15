/* Автор: Paul Gordon, ноябрь 2026 */

using Xunit;

namespace Server.Tests;

/// <summary>
/// Zuluhotel 2026-11-15: после рестарта у игрока пропала собранная паутина. Мир сохранялся раз в час, а Ctrl+C,
/// консольные restart и shutdown и закрытие окна выходили без сохранения: всё с последнего сейва откатывалось.
/// [SafeRestart просил сейв и тут же останов, а цикл на останове ждал запись, которую сам же и должен был сделать.
/// Теперь штатный выход сначала сохраняет мир, а уже идущий сейв дожидается.
/// </summary>
public class ExitSaveTests
{
    [Fact]
    public void ARunningWorldIsSavedBeforeExit() =>
        Assert.Equal(Core.ExitStep.StartSave, Core.NextExitStep(WorldState.Running, false, false));

    [Fact]
    public void ASaveAlreadyRequestedIsWaitedFor()
    {
        // [SafeRestart: сейв запрошен, снимок мира ещё не снят - цикл должен крутиться, а не блокироваться.
        Assert.Equal(Core.ExitStep.KeepRunning, Core.NextExitStep(WorldState.PendingSave, false, false));
        Assert.Equal(Core.ExitStep.KeepRunning, Core.NextExitStep(WorldState.Saving, true, false));
    }

    [Fact]
    public void ATakenSnapshotIsWrittenThenTheServerExits()
    {
        Assert.Equal(Core.ExitStep.Exit, Core.NextExitStep(WorldState.WritingSave, true, false));
        Assert.Equal(Core.ExitStep.Exit, Core.NextExitStep(WorldState.Running, true, false)); // второй раз не сохраняем
    }

    [Fact]
    public void ASaveThatJustFinishedIsNotRepeated() =>
        Assert.Equal(Core.ExitStep.Exit, Core.NextExitStep(WorldState.WritingSave, false, false));

    [Fact]
    public void AWorldThatIsNotRunningIsNotSaved()
    {
        Assert.Equal(Core.ExitStep.Exit, Core.NextExitStep(WorldState.Loading, false, false));
        Assert.Equal(Core.ExitStep.Exit, Core.NextExitStep(WorldState.Initial, false, false));
    }

    [Fact]
    public void AStuckSaveDoesNotHoldTheServerForever() =>
        Assert.Equal(Core.ExitStep.Exit, Core.NextExitStep(WorldState.PendingSave, true, true));
}
