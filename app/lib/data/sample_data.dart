import 'package:flutter/material.dart';

import '../models/category.dart';
import '../models/location.dart';
import '../models/product.dart';
import '../models/shift.dart';
import '../core/statuses.dart';

abstract class SampleData {
  static const locations = <Location>[
    Location(
      id: 1,
      name: 'Площад „Светлина“',
      address: 'ул. Централна 12, София',
    ),
    Location(
      id: 2,
      name: 'Квартален пункт „Младост“',
      address: 'бул. Александър Малинов 45, София',
    ),
    Location(
      id: 3,
      name: 'Пункт „Тракия“',
      address: 'ул. Христо Ботев 8, Пловдив',
    ),
    Location(id: 4, name: 'Пункт „Северен“', address: 'бул. Дунав 3, Варна'),
    Location(
      id: 5,
      name: 'Пункт „Централен пазар“',
      address: 'ул. Княз Александър 20, Бургас',
      isActive: false,
    ),
  ];

  static const categories = <Category>[
    Category(id: 1, name: 'Храни', icon: Icons.inventory_2_outlined),
    Category(id: 2, name: 'Дрехи', icon: Icons.checkroom_outlined),
    Category(id: 3, name: 'Хигиена', icon: Icons.soap_outlined),
    Category(id: 4, name: 'Играчки', icon: Icons.toys_outlined),
  ];

  static const products = <Product>[
    Product(id: 1, categoryId: 1, name: 'Ориз', unitLabel: 'кг'),
    Product(id: 2, categoryId: 1, name: 'Брашно', unitLabel: 'кг'),
    Product(id: 3, categoryId: 1, name: 'Консерви', unitLabel: 'бр.'),
    Product(id: 4, categoryId: 1, name: 'Олио', unitLabel: 'л'),
    Product(id: 5, categoryId: 2, name: 'Зимно палто', unitLabel: 'бр.'),
    Product(id: 6, categoryId: 2, name: 'Тениска', unitLabel: 'бр.'),
    Product(id: 7, categoryId: 2, name: 'Чорапи', unitLabel: 'чифт'),
    Product(id: 8, categoryId: 3, name: 'Шампоан', unitLabel: 'бр.'),
    Product(id: 9, categoryId: 3, name: 'Паста за зъби', unitLabel: 'бр.'),
    Product(id: 10, categoryId: 3, name: 'Сапун', unitLabel: 'бр.'),
    Product(id: 11, categoryId: 4, name: 'Плюшена играчка', unitLabel: 'бр.'),
    Product(id: 12, categoryId: 4, name: 'Пъзел', unitLabel: 'бр.'),
  ];

  static final List<Shift> shifts = <Shift>[
    Shift(
      id: 1,
      title: 'Вечерен събиране — София',
      description: 'Събиране на храни и дрехи на площад „Светлина“.',
      date: DateTime(2026, 10, 20),
      startTime: '17:00',
      endTime: '21:00',
      locationIds: const [1],
      status: ShiftStatus.available,
      registeredCount: 6,
      capacity: 12,
    ),
    Shift(
      id: 2,
      title: 'Утринен събиране — Младост',
      description: 'Ранна смяна за прием и сортиране на дарения.',
      date: DateTime(2026, 10, 21),
      startTime: '08:00',
      endTime: '12:00',
      locationIds: const [2],
      status: ShiftStatus.almostFull,
      registeredCount: 9,
      capacity: 10,
    ),
    Shift(
      id: 3,
      title: 'Голям дарителски ден — Пловдив',
      description: 'Пълномащабна кампания на пункта в „Тракия“.',
      date: DateTime(2026, 10, 22),
      startTime: '09:00',
      endTime: '18:00',
      locationIds: const [1, 3],
      status: ShiftStatus.full,
      registeredCount: 15,
      capacity: 15,
    ),
    Shift(
      id: 4,
      title: 'Сортировъчна смяна — Варна',
      description: 'Сортиране и пакетиране на постъпили дарения.',
      date: DateTime(2026, 10, 18),
      startTime: '10:00',
      endTime: '14:00',
      locationIds: const [4],
      status: ShiftStatus.inProcess,
      registeredCount: 4,
      capacity: 8,
    ),
    Shift(
      id: 5,
      title: 'Сутрешен прием — София',
      description: 'Завършена смяна с отчет на входираните количества.',
      date: DateTime(2026, 10, 17),
      startTime: '08:00',
      endTime: '12:00',
      locationIds: const [1, 2],
      status: ShiftStatus.completed,
      registeredCount: 7,
      capacity: 10,
    ),
    Shift(
      id: 6,
      title: 'Подготовка за кампанията',
      description: 'Предстояща смяна за подготовка на пунктовете.',
      date: DateTime(2026, 11, 2),
      startTime: '15:00',
      endTime: '19:00',
      locationIds: const [3],
      status: ShiftStatus.upcoming,
      registeredCount: 2,
      capacity: 10,
    ),
    Shift(
      id: 7,
      title: 'Пробна смяна — Бургас',
      description: 'Архивирана пилотна смяна при закрития пункт.',
      date: DateTime(2026, 9, 10),
      startTime: '10:00',
      endTime: '13:00',
      locationIds: const [5],
      status: ShiftStatus.archived,
      registeredCount: 3,
      capacity: 6,
    ),
    Shift(
      id: 8,
      title: 'Вечерен събиране — Младост',
      description: 'Отворена смяна с останали места за доброволци.',
      date: DateTime(2026, 10, 23),
      startTime: '17:30',
      endTime: '20:30',
      locationIds: const [2, 4],
      status: ShiftStatus.available,
      registeredCount: 3,
      capacity: 12,
    ),
  ];
}
