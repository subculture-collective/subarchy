import QtQuick
import QtTest
import "../Model.js" as Model

TestCase {
  name: "Tray"

  readonly property int passive: 0
  readonly property int left: 1
  readonly property int right: 2
  readonly property int middle: 4

  function test_passiveItemsAreHidden() {
    const items = [{ id: "a", status: 0 }, { id: "b", status: 1 }, { id: "c", status: 2 }]
    compare(Model.visible(items, passive).map(i => i.id), ["b", "c"])
  }

  function test_noItems() {
    compare(Model.visible([], passive), [])
    compare(Model.visible(null, passive), [])
  }

  function test_rightClickOpensMenu() {
    compare(Model.action({ hasMenu: true, onlyMenu: false }, right), "menu")
  }

  function test_rightClickWithoutMenuActivates() {
    compare(Model.action({ hasMenu: false, onlyMenu: false }, right), "activate")
  }

  function test_leftClickOnMenuOnlyItemOpensMenu() {
    compare(Model.action({ hasMenu: true, onlyMenu: true }, left), "menu")
  }

  function test_leftClickActivates() {
    compare(Model.action({ hasMenu: true, onlyMenu: false }, left), "activate")
  }

  function test_middleClickIsSecondary() {
    compare(Model.action({ hasMenu: true, onlyMenu: true }, middle), "secondary")
    compare(Model.action({ hasMenu: false, onlyMenu: false }, middle), "secondary")
  }
}
