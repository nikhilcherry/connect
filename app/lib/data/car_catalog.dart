// Popular Indian cars with manufacturer exterior dimensions (length x width x
// height, mm; width excludes mirrors). Figures are for the current generation
// as commonly published and can differ by variant, so the app shows them as
// editable defaults rather than facts about the user's car.

class CarSpec {
  const CarSpec(this.make, this.model, this.lengthMm, this.widthMm, this.heightMm);
  final String make;
  final String model;
  final int lengthMm;
  final int widthMm;
  final int heightMm;

  String get name => '$make $model';
}

const carCatalog = <CarSpec>[
  CarSpec('Maruti Suzuki', 'Alto K10', 3530, 1490, 1520),
  CarSpec('Maruti Suzuki', 'Wagon R', 3655, 1620, 1675),
  CarSpec('Maruti Suzuki', 'Swift', 3860, 1735, 1520),
  CarSpec('Maruti Suzuki', 'Dzire', 3995, 1735, 1525),
  CarSpec('Maruti Suzuki', 'Baleno', 3990, 1745, 1500),
  CarSpec('Maruti Suzuki', 'Fronx', 3995, 1765, 1550),
  CarSpec('Maruti Suzuki', 'Brezza', 3995, 1790, 1685),
  CarSpec('Maruti Suzuki', 'Ertiga', 4395, 1735, 1690),
  CarSpec('Maruti Suzuki', 'Grand Vitara', 4345, 1795, 1645),
  CarSpec('Hyundai', 'Exter', 3815, 1710, 1631),
  CarSpec('Hyundai', 'i20', 3995, 1775, 1505),
  CarSpec('Hyundai', 'Venue', 3995, 1770, 1617),
  CarSpec('Hyundai', 'Creta', 4330, 1790, 1635),
  CarSpec('Hyundai', 'Verna', 4535, 1765, 1475),
  CarSpec('Tata', 'Tiago', 3765, 1677, 1535),
  CarSpec('Tata', 'Punch', 3827, 1742, 1615),
  CarSpec('Tata', 'Nexon', 3995, 1804, 1620),
  CarSpec('Tata', 'Harrier', 4605, 1922, 1718),
  CarSpec('Tata', 'Safari', 4668, 1922, 1795),
  CarSpec('Mahindra', 'Thar', 3985, 1820, 1855),
  CarSpec('Mahindra', 'XUV 3XO', 3990, 1821, 1647),
  CarSpec('Mahindra', 'Bolero', 3995, 1745, 1880),
  CarSpec('Mahindra', 'Scorpio-N', 4662, 1917, 1857),
  CarSpec('Mahindra', 'XUV700', 4695, 1890, 1755),
  CarSpec('Kia', 'Sonet', 3995, 1790, 1642),
  CarSpec('Kia', 'Seltos', 4365, 1800, 1645),
  CarSpec('Kia', 'Carens', 4540, 1800, 1708),
  CarSpec('Toyota', 'Innova Hycross', 4695, 1850, 1795),
  CarSpec('Toyota', 'Innova Crysta', 4735, 1830, 1795),
  CarSpec('Toyota', 'Fortuner', 4795, 1855, 1835),
  CarSpec('Honda', 'Amaze', 3995, 1733, 1500),
  CarSpec('Honda', 'Elevate', 4312, 1790, 1650),
  CarSpec('Honda', 'City', 4583, 1748, 1489),
  CarSpec('MG', 'Windsor EV', 4295, 1850, 1677),
  CarSpec('MG', 'Hector', 4699, 1835, 1760),
  CarSpec('Renault', 'Kwid', 3731, 1579, 1490),
  CarSpec('Renault', 'Kiger', 3991, 1750, 1605),
  CarSpec('Skoda', 'Kushaq', 4225, 1760, 1612),
  CarSpec('Volkswagen', 'Virtus', 4561, 1752, 1507),
];
