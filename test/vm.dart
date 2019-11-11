@TestOn("vm")

import "package:test/test.dart";
import "package:juicer/juicer_vm.dart";
import "package:juicer/metadata.dart";

import "sample_classes/sample_classes.dart";
import "sample_classes/sample_gen.dart";

@juiced
class B {
  @override
  String toString() => "B($b)";

  bool b;
}

@juiced
class A {
  @override
  String toString() => "A($bs)";

  List<B> bs;
}

void main() {
  test("Test encoding and decoding on the VM", () {
    RegExp matcher = RegExp(r"juicer/test/sample_classes/[^/]+$");
    Juicer juicer = createJuicerForLibraries(
        packageUriFilter: (uri) => matcher.hasMatch(uri.path));
    Something sg = createSampleSomething();
    dynamic val = juicer.encode(sg);
    matchSomething(val, sg);
    dynamic recoded = recode(juicer.encode(sg));
    Something redecoded = juicer.decode(recoded, (_) => Something());
    matchSomething(juicer.encode(redecoded), sg);
  });
  test("juiceClasses", () {
    Juicer ownJuicer = juiceClasses([A], juiceReferenced: true);
    expect(ownJuicer.mappers.keys.toSet(), [A, B].toSet());
    A original = A()..bs = [B()..b = true, B()..b = false];
    String ownJson = ownJuicer.encodeJson(original);
    A copy = ownJuicer.decodeJson(ownJson, (_) => A());
    expect(copy.bs.length, original.bs.length);
    for (int i = 0; i < original.bs.length; ++i) {
      expect(copy.bs[i].b, original.bs[i].b);
    }
  });
}
