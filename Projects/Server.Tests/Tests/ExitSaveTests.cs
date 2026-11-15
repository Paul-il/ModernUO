/* Автор: Paul Gordon, ноябрь 2026 */

using Xunit;

namespace Server.Tests;

/// <summary>
/// Zuluhotel 2026-11-15: после рестарта у игрока пропала собранная паутина. Мир сохранялся раз в час, Ctrl+C выходил без
/// сохранения, а [SafeRestart просил сейв и тут же останов: цикл на останове ждал запись, снимок для которой сам же должен
/// был снять, и сервер висел, пока его не закрывали руками - всё с последнего автосейва откатывалось.
/// Теперь Ctrl+C сначала сохраняет мир, запрошенный сейв дожидается, а остановка без сейва (вайп, откат) остаётся без сейва.
/// </summary>
public class ExitSaveTests
{
    [Fact]
    public void ARunningWorldIsSavedBeforeExit() =>
        Assert.Equal(Core.ExitStep.StartSave, Core.NextExitStep(WorldState.Running, true, false));

    [Fact]
    public void AStopWithoutSaveLeavesTheDiskAsItWas()
    {
        // Вайп, упавший на середине, и «Shutdown (Without Save)»: полуизменённый мир не должен попасть на диск.
        Assert.Equal(Core.ExitStep.Exit, Core.NextExitStep(WorldState.Running, false, false));
        Assert.Equal(Core.ExitStep.Exit, Core.NextExitStep(WorldState.WritingSave, false, false));
    }

    [Fact]
    public void ASaveAlreadyRequestedIsWaitedFor()
    {
        // [SafeRestart: сейв запрошен, снимок ещё не снят - цикл должен крутиться, а не блокироваться. С сейвом и без.
        Assert.Equal(Core.ExitStep.AwaitSnapshot, Core.NextExitStep(WorldState.PendingSave, false, false));
        Assert.Equal(Core.ExitStep.AwaitSnapshot, Core.NextExitStep(WorldState.PendingSave, true, false));
        Assert.Equal(Core.ExitStep.AwaitSnapshot, Core.NextExitStep(WorldState.Saving, true, true));
    }

    [Fact]
    public void ATakenSnapshotIsWrittenThenTheServerExits()
    {
        Assert.Equal(Core.ExitStep.Exit, Core.NextExitStep(WorldState.WritingSave, true, true));
        Assert.Equal(Core.ExitStep.Exit, Core.NextExitStep(WorldState.Running, true, true)); // второй раз не сохраняем
    }

    [Fact]
    public void AnOldSnapshotStillBeingWrittenIsNotEnough() =>
        // Автосейв снят до команды и ещё пишется: дождаться записи и сохранить заново, иначе изменения после него пропадут.
        Assert.Equal(Core.ExitStep.AwaitWrite, Core.NextExitStep(WorldState.WritingSave, true, false));

    [Fact]
    public void AWorldThatIsNotRunningIsNotSaved()
    {
        Assert.Equal(Core.ExitStep.Exit, Core.NextExitStep(WorldState.Loading, true, false));
        Assert.Equal(Core.ExitStep.Exit, Core.NextExitStep(WorldState.Initial, true, false));
    }
}
