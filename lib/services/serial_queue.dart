/// Runs async operations one after another, in the order they were added.
///
/// A failing operation does not stop the ones after it; its error goes to its
/// own caller only.
class SerialQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() op) {
    final result = _tail.then((_) => op());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
