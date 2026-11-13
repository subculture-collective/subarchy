import QtQuick
import QtTest

import "../AltSwitchModel.js" as Model

TestCase {
  name: "AltSwitch"

  function test_orderRecentFirst() {
    const clients = ["a", "b", "c", "d"]
    compare(Model.order(clients, ["c", "a"]), ["c", "a", "b", "d"])
  }

  function test_orderDropsClosedWindows() {
    compare(Model.order(["a", "b"], ["x", "b", "y"]), ["b", "a"])
  }

  function test_remember() {
    compare(Model.remember(["a", "b", "c"], "c", 10), ["c", "a", "b"])
    compare(Model.remember(["a", "b"], "z", 2), ["z", "a"])
    compare(Model.remember(["a"], "", 10), ["a"])
  }

  function test_nextWraps() {
    const order = ["a", "b", "c"]
    compare(Model.next(order, 0, 1), 1)
    compare(Model.next(order, 2, 1), 0)
    compare(Model.next(order, 0, -1), 2)
    compare(Model.next([], 0, 1), -1)
  }

  function test_startsOnPrevious() {
    compare(Model.start(["a", "b", "c"], 1), 1, "Alt-Tab starts on the window used before this one")
    compare(Model.start(["a"], 1), 0)
    compare(Model.start(["a", "b"], -1), 1, "Alt-Shift-Tab starts on the oldest")
  }

  function test_focusRank() {
    verify(Model.focusRank({ focusHistoryID: 0 }) < Model.focusRank({ focusHistoryID: 1 }), "the focused window first")
    verify(Model.focusRank({ focusHistoryID: 3 }) < Model.focusRank(undefined), "no IPC object: last")
    verify(Model.focusRank({ focusHistoryID: 3 }) < Model.focusRank({ focusHistoryID: -1 }), "-1: last")
    verify(Model.focusRank({ focusHistoryID: 3 }) < Model.focusRank({}), "missing: last")
  }

  // After a shell start the history is empty; the clients arrive sorted by
  // Hyprland's focus history, focused window first, so Alt-Tab picks the
  // window used before it.
  function test_startsOnPreviousWithEmptyHistory() {
    const ipc = { a: { focusHistoryID: 1 }, b: { focusHistoryID: 0 } }
    const clients = ["a", "b"].sort((x, y) => Model.focusRank(ipc[x]) - Model.focusRank(ipc[y]))
    compare(clients, ["b", "a"])
    const order = Model.order(clients, [])
    compare(order[Model.start(order, 1)], "a")
  }
}
