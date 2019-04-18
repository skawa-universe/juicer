import "package:juicer/metadata.dart" as juicer;
import "different.dart";

class Juiced {
  const Juiced();
}

@juicer.juiced
@Juiced()
class Something {
  @override
  String toString() => "Something($simpleNum)";

  num simpleNum;

  @juicer.Property(name: "getterDecoration")
  int get b => 0xb;

  set b(int val) {}

  int get c => 0xc;

  @juicer.Property(name: "setterDecoration")
  set c(int val) {}

  double sampleDouble;

  double integerDouble;

  @juicer.Property(ignore: true)
  int get ignored1 => 0;

  set ignored1(int val) {}

  int get ignored2 => 0;

  @juicer.Property(ignore: true)
  set ignored2(int val) {}

  Different completelyDifferent;

  Map<String, dynamic> rawMap;

  List<Different> differentList;

  Iterable<Different> differentIterable;

  Map<String, int> intMap;
}
