import 'dart:convert';
import 'package:juicer/juicer_vm.dart';
import 'package:juicer/metadata.dart';

@juiced
class Party {
  String key;
  String name;
  String country;
  String city;
  @Property(name: 'street_address')
  String streetAddress;
  String zip;

  @Property(ignore: true)
  String get address => '$name\n$streetAddress\n$city\n$country';

  Map<String, dynamic> aux;
}

void main() {
  var juicer = juiceClasses([Party]);
  var asMap = juicer.encode(Party()
    ..key = 'company_1234556'
    ..name = 'Random Ltd.'
    ..country = 'Sovereignland'
    ..city = 'Capitalcity'
    ..streetAddress = '1 Main Street'
    ..zip = '11111');
  print(json.encode(asMap));
  print(juicer.decode(asMap, (_) => Party()).address);
  print(juicer
      .decodeJson(
          json.encode({
            'aux': {
              'alpha': [
                'bravo',
                {'charlie': 4, 'delta': true, 'echo': 3.14},
                null
              ],
              'foxtrot': {'golf': 'hotel'}
            }
          }),
          (_) => Party())
      .aux);
}
