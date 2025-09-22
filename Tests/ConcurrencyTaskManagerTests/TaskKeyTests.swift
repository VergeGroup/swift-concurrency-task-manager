import Testing
import ConcurrencyTaskManager

@Suite struct TaskKeyTests {

  @Test func base() {

    enum LocalKey: TaskKeyType {}
    enum LocalKey2: TaskKeyType {}

    let key = TaskKey(LocalKey.self)
    let key2 = TaskKey(LocalKey2.self)

    #expect(key != key2)
    #expect(key == key)
  }

  @Test func combined() {

    enum LocalKey: TaskKeyType {}

    let key = TaskKey(LocalKey.self)

    #expect(key == key.combined(.init(LocalKey.self)))
    #expect(key != key.combined("A"))

  }

}
