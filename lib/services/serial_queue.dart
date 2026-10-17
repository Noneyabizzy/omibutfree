/// Runs async operations one after another, in the order they were added.
///
/// A failing operation does not stop the ones after it; its error goes to its
/// own caller only. Callers must await the future returned by [run] (or handle
/// its error): the queue itself does not report a failure nobody is waiting on.
class SerialQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() op) {
    final result = _tail.then((_) => op());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
