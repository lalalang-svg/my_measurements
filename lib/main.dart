import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MeasurementsApp());
}

class Reading {
  final int id;
  final String measuredAt;
  final int? pulse;
  final int? systolic;
  final int? diastolic;
  final int? glucoseTenths;
  final String glucoseContext;
  final String note;

  Reading.fromMap(Map<String, Object?> row)
      : id = row['id'] as int,
        measuredAt = row['measured_at'] as String,
        pulse = row['pulse'] as int?,
        systolic = row['systolic'] as int?,
        diastolic = row['diastolic'] as int?,
        glucoseTenths = row['glucose_tenths'] as int?,
        glucoseContext = row['glucose_context'] as String,
        note = row['note'] as String;

  String get glucoseText => glucoseTenths == null
      ? '—'
      : (glucoseTenths! / 10).toStringAsFixed(1);
  String get pressureText => systolic == null ? '—' : '$systolic/$diastolic';
}

class LocalStore {
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final file = p.join(await getDatabasesPath(), 'my_measurements.db');
    _db = await openDatabase(file, version: 1, onCreate: (db, version) async {
      await db.execute('''CREATE TABLE measurements (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        measured_at TEXT NOT NULL,
        pulse INTEGER CHECK (pulse BETWEEN 20 AND 250),
        systolic INTEGER CHECK (systolic BETWEEN 50 AND 300),
        diastolic INTEGER CHECK (diastolic BETWEEN 30 AND 200),
        glucose_tenths INTEGER CHECK (glucose_tenths BETWEEN 10 AND 400),
        glucose_context TEXT NOT NULL DEFAULT 'unknown'
          CHECK (glucose_context IN ('unknown', 'fasting', 'after_meal')),
        note TEXT NOT NULL DEFAULT '' CHECK (length(note) <= 500),
        CHECK (pulse IS NOT NULL OR systolic IS NOT NULL OR glucose_tenths IS NOT NULL),
        CHECK ((systolic IS NULL) = (diastolic IS NULL)),
        CHECK (systolic IS NULL OR systolic > diastolic),
        CHECK (glucose_tenths IS NOT NULL OR glucose_context = 'unknown')
      )''');
      await db.execute('''CREATE TABLE personal_targets (
        metric TEXT NOT NULL CHECK (metric = 'glucose_tenths'),
        context TEXT NOT NULL CHECK (context = 'fasting'),
        upper_limit INTEGER NOT NULL CHECK (upper_limit BETWEEN 10 AND 400),
        PRIMARY KEY (metric, context)
      )''');
      await db.execute('CREATE INDEX idx_measurements_time '
          'ON measurements(measured_at DESC, id DESC)');
      await db.execute('CREATE INDEX idx_measurements_context_time '
          'ON measurements(glucose_context, measured_at DESC) '
          'WHERE glucose_tenths IS NOT NULL');
    });
    return _db!;
  }

  Future<List<Reading>> list() async {
    final db = await database;
    final rows = await db.query('measurements', orderBy: 'measured_at DESC, id DESC');
    return rows.map(Reading.fromMap).toList();
  }

  Future<int?> fastingTarget() async {
    final db = await database;
    final rows = await db.query('personal_targets', columns: ['upper_limit'],
        where: 'metric = ? AND context = ?',
        whereArgs: ['glucose_tenths', 'fasting']);
    return rows.isEmpty ? null : rows.first['upper_limit'] as int;
  }

  Future<void> setFastingTarget(int? tenths) async {
    final db = await database;
    if (tenths == null) {
      await db.delete('personal_targets', where: 'metric = ? AND context = ?',
          whereArgs: ['glucose_tenths', 'fasting']);
    } else {
      await db.insert('personal_targets', {
        'metric': 'glucose_tenths', 'context': 'fasting', 'upper_limit': tenths,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<void> add({required String date, int? pulse, int? systolic,
      int? diastolic, int? glucoseTenths, required String context,
      required String note}) async {
    final db = await database;
    await db.insert('measurements', {
      'measured_at': date, 'pulse': pulse, 'systolic': systolic,
      'diastolic': diastolic, 'glucose_tenths': glucoseTenths,
      'glucose_context': glucoseTenths == null ? 'unknown' : context,
      'note': note,
    });
  }

  Future<void> seedDemo() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('measurements');
      await txn.delete('personal_targets');
      await txn.insert('personal_targets', {
        'metric': 'glucose_tenths', 'context': 'fasting', 'upper_limit': 55,
      });
      final examples = [
        ['2026-03-01T09:00', 72, 120, 80, 52, 'unknown'],
        ['2026-03-02T09:00', 75, 125, 82, 54, 'unknown'],
        ['2026-03-03T09:00', 80, 130, 85, 56, 'unknown'],
        ['2026-03-04T09:00', 78, 128, 84, 56, 'fasting'],
      ];
      for (final row in examples) {
        await txn.insert('measurements', {
          'measured_at': row[0], 'pulse': row[1],
          'systolic': row[2], 'diastolic': row[3],
          'glucose_tenths': row[4], 'glucose_context': row[5],
          'note': row[0] == '2026-03-03T09:00'
              ? 'Условия измерения не указаны' : '',
        });
      }
    });
  }
}

String contextLabel(String context) {
  switch (context) {
    case 'fasting': return 'натощак';
    case 'after_meal': return 'после еды';
    default: return 'контекст не указан';
  }
}

String resultFor(Reading r, int? fastingTarget) {
  if (r.glucoseTenths == null) return 'Запись сохранена';
  if (r.glucoseContext == 'unknown') {
    return 'Глюкоза: условия измерения не указаны, сравнение недоступно';
  }
  if (r.glucoseContext == 'after_meal') {
    return 'Глюкоза: личный ориентир после еды не задан';
  }
  if (fastingTarget == null) return 'Глюкоза: личный ориентир не задан';
  if (r.glucoseTenths! > fastingTarget) {
    return 'Глюкоза ${r.glucoseText} выше личного ориентира '
        '${(fastingTarget / 10).toStringAsFixed(1)} ммоль/л';
  }
  return 'Глюкоза: превышения личного ориентира нет';
}

int? parseOptionalInteger(String raw, String label, int min, int max) {
  if (raw.trim().isEmpty) return null;
  final n = int.tryParse(raw.trim());
  if (n == null || n < min || n > max) {
    throw FormatException('$label: укажите целое число от $min до $max');
  }
  return n;
}

int? parseGlucose(String raw) {
  final value = raw.trim().replaceAll(',', '.');
  if (value.isEmpty) return null;
  if (!RegExp(r'^\d+(\.\d)?$').hasMatch(value)) {
    throw const FormatException('Глюкоза: используйте не более одного знака после запятой');
  }
  final tenths = (double.parse(value) * 10).round();
  if (tenths < 10 || tenths > 400) {
    throw const FormatException('Глюкоза: технический диапазон от 1,0 до 40,0');
  }
  return tenths;
}

class MeasurementsApp extends StatelessWidget {
  const MeasurementsApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Мои измерения', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xff176274)),
    home: const MeasurementsHome(),
  );
}

class PulseChart extends CustomPainter {
  final List<int> points;
  PulseChart(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    const left = 14.0;
    final right = size.width - 14;
    const top = 14.0;
    final bottom = size.height - 18;
    final smallest = points.reduce((a, b) => a < b ? a : b).toDouble();
    final largest = points.reduce((a, b) => a > b ? a : b).toDouble();
    final span = largest == smallest ? 1.0 : largest - smallest;
    final line = Paint()..color = const Color(0xff176274)
      ..strokeWidth = 3..style = PaintingStyle.stroke;
    final dot = Paint()..color = const Color(0xff176274);
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = left + (right - left) * (points.length == 1 ? .5 : i / (points.length - 1));
      final y = bottom - (points[i] - smallest) / span * (bottom - top);
      if (i == 0) { path.moveTo(x, y); } else { path.lineTo(x, y); }
      canvas.drawCircle(Offset(x, y), 4, dot);
    }
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(covariant PulseChart oldDelegate) =>
      oldDelegate.points.toString() != points.toString();
}

class MeasurementsHome extends StatefulWidget {
  const MeasurementsHome({super.key});
  @override
  State<MeasurementsHome> createState() => _MeasurementsHomeState();
}

class _MeasurementsHomeState extends State<MeasurementsHome> {
  final store = LocalStore();
  final pulse = TextEditingController();
  final systolic = TextEditingController();
  final diastolic = TextEditingController();
  final glucose = TextEditingController();
  final note = TextEditingController();
  final target = TextEditingController();
  DateTime moment = DateTime.now();
  String glucoseContext = 'unknown';
  List<Reading> entries = [];
  int? fastingTarget;
  int tab = 0;
  bool busy = true;

  @override
  void initState() { super.initState(); reload(); }

  Future<void> reload() async {
    try {
      final rows = await store.list();
      final limit = await store.fastingTarget();
      if (!mounted) return;
      setState(() { entries = rows; fastingTarget = limit; busy = false; });
      target.text = limit == null ? '' : (limit / 10).toStringAsFixed(1);
    } catch (error) {
      if (mounted) {
        setState(() => busy = false);
        show('Ошибка чтения базы: $error');
      }
    }
  }

  void show(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> pickDate() async {
    final date = await showDatePicker(context: context, initialDate: moment,
        firstDate: DateTime(2000), lastDate: DateTime(2100));
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context,
        initialTime: TimeOfDay.fromDateTime(moment));
    if (!mounted) return;
    setState(() => moment = DateTime(date.year, date.month, date.day,
        time?.hour ?? moment.hour, time?.minute ?? moment.minute));
  }

  Future<void> saveReading() async {
    try {
      final a = parseOptionalInteger(pulse.text, 'Пульс', 20, 250);
      final b = parseOptionalInteger(systolic.text, 'Верхнее давление', 50, 300);
      final c = parseOptionalInteger(diastolic.text, 'Нижнее давление', 30, 200);
      final d = parseGlucose(glucose.text);
      if ((b == null) != (c == null) || (b != null && b <= c!)) {
        throw const FormatException('Давление вводится парой, верхнее должно быть выше нижнего');
      }
      if (a == null && b == null && d == null) {
        throw const FormatException('Укажите хотя бы один показатель');
      }
      if (note.text.length > 500) {
        throw const FormatException('Примечание должно быть короче 500 символов');
      }
      await store.add(date: moment.toIso8601String().substring(0, 16), pulse: a,
          systolic: b, diastolic: c, glucoseTenths: d,
          context: glucoseContext, note: note.text.trim());
      pulse.clear(); systolic.clear(); diastolic.clear(); glucose.clear(); note.clear();
      if (!mounted) return;
      await reload();
      if (!mounted) return;
      setState(() => tab = 1);
      show('Измерение сохранено');
    } on FormatException catch (error) {
      show(error.message);
    } catch (error) {
      show('Ошибка сохранения: $error');
    }
  }

  Future<void> saveTarget() async {
    try {
      final n = parseGlucose(target.text);
      await store.setFastingTarget(n);
      if (!mounted) return;
      await reload();
      if (mounted) show(n == null ? 'Ориентир удален' : 'Личный ориентир сохранен');
    } on FormatException catch (error) {
      show(error.message);
    } catch (error) {
      show('Ошибка сохранения ориентира: $error');
    }
  }

  Future<void> loadDemo() async {
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) =>
      AlertDialog(title: const Text('Загрузить учебные записи?'),
        content: const Text('Все текущие измерения и личный ориентир будут заменены учебным набором.'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Загрузить'))]));
    if (confirmed != true) return;
    try {
      await store.seedDemo();
      if (!mounted) return;
      await reload();
      if (!mounted) return;
      setState(() => tab = 1);
      show('Учебные измерения загружены');
    } catch (error) {
      if (mounted) show('Ошибка загрузки: $error');
    }
  }

  @override
  void dispose() {
    pulse.dispose(); systolic.dispose(); diastolic.dispose();
    glucose.dispose(); note.dispose(); target.dispose();
    super.dispose();
  }

  Widget input(String title, TextEditingController controller, {String? hint}) =>
      Padding(padding: const EdgeInsets.only(bottom: 13), child: TextField(
        controller: controller, keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: title, hintText: hint,
            border: const OutlineInputBorder())));

  Widget inputTab() => ListView(padding: const EdgeInsets.all(18), children: [
    const Text('Новое измерение', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
    const SizedBox(height: 8),
    const Text('Можно заполнить только измеренные показатели. Для глюкозы укажите условия измерения.'),
    const SizedBox(height: 18),
    OutlinedButton.icon(onPressed: pickDate, icon: const Icon(Icons.calendar_today),
        label: Text('Дата и время: ${moment.toLocal().toString().substring(0, 16)}')),
    const SizedBox(height: 15),
    input('Пульс, уд/мин', pulse),
    input('Верхнее давление, мм рт. ст.', systolic),
    input('Нижнее давление, мм рт. ст.', diastolic),
    input('Глюкоза, ммоль/л', glucose, hint: 'Например, 5,6'),
    DropdownButtonFormField<String>(initialValue: glucoseContext,
      decoration: const InputDecoration(labelText: 'Условия измерения глюкозы',
          border: OutlineInputBorder()),
      items: const [DropdownMenuItem(value: 'unknown', child: Text('Не указаны')),
        DropdownMenuItem(value: 'fasting', child: Text('Натощак')),
        DropdownMenuItem(value: 'after_meal', child: Text('После еды'))],
      onChanged: (v) => setState(() => glucoseContext = v ?? 'unknown')),
    const SizedBox(height: 14),
    TextField(controller: note, maxLength: 500, maxLines: 2,
        decoration: const InputDecoration(labelText: 'Примечание', border: OutlineInputBorder())),
    FilledButton.icon(onPressed: saveReading, icon: const Icon(Icons.save_outlined),
        label: const Text('Сохранить измерение')),
    const SizedBox(height: 12),
    const Text('Технические пределы ввода защищают от опечаток и не обозначают медицинскую норму.',
        style: TextStyle(fontSize: 12)),
  ]);

  Widget historyTab() => entries.isEmpty
      ? const Center(child: Text('Измерений пока нет. Добавьте запись или загрузите учебный набор.'))
      : ListView.builder(padding: const EdgeInsets.all(14), itemCount: entries.length,
          itemBuilder: (ctx, i) {
            final r = entries[i];
            final status = resultFor(r, fastingTarget);
            return Card(margin: const EdgeInsets.only(bottom: 12), child:
              Padding(padding: const EdgeInsets.all(16), child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.measuredAt.replaceFirst('T', ' '),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('Пульс: ${r.pulse ?? '—'} уд/мин     Давление: ${r.pressureText}'),
                  Text('Глюкоза: ${r.glucoseText} ммоль/л '
                       '(${contextLabel(r.glucoseContext)})'),
                  if (r.note.isNotEmpty) Text('Примечание: ${r.note}'),
                  const SizedBox(height: 9),
                  Text(status, style: TextStyle(color: status.contains('выше')
                      ? Colors.deepOrange.shade800 : Colors.teal.shade800)),
                ])));
          });

  double? mean(Iterable<int?> values) {
    final available = values.whereType<int>().toList();
    if (available.isEmpty) return null;
    return available.reduce((a, b) => a + b) / available.length;
  }

  Widget overviewTab() {
    final pulseMean = mean(entries.map((r) => r.pulse));
    final sysMean = mean(entries.map((r) => r.systolic));
    final diaMean = mean(entries.map((r) => r.diastolic));
    final unknown = mean(entries.where((r) => r.glucoseContext == 'unknown')
        .map((r) => r.glucoseTenths));
    final fasting = mean(entries.where((r) => r.glucoseContext == 'fasting')
        .map((r) => r.glucoseTenths));
    final chronologicalPulse = entries.reversed.map((r) => r.pulse)
        .whereType<int>().toList();
    String n(double? value, {bool glucose = false}) => value == null
        ? '—' : (glucose ? value / 10 : value).toStringAsFixed(1);
    return ListView(padding: const EdgeInsets.all(18), children: [
      const Text('Сводка измерений', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Записей: ${entries.length}'),
          Text('Средний пульс: ${n(pulseMean)} уд/мин'),
          Text('Среднее давление: ${n(sysMean)}/${n(diaMean)} мм рт. ст.'),
          Text('Глюкоза, контекст не указан: ${n(unknown, glucose: true)} ммоль/л'),
          Text('Глюкоза натощак: ${n(fasting, glucose: true)} ммоль/л'),
        ]))),
      const SizedBox(height: 10),
      const Text('Значения глюкозы с разными условиями измерения не объединяются в одно среднее.'),
      const SizedBox(height: 18),
      const Text('Пульс по времени', style: TextStyle(fontWeight: FontWeight.bold)),
      if (chronologicalPulse.isEmpty) const Text('Для графика нужны измерения пульса'),
      if (chronologicalPulse.isNotEmpty) SizedBox(height: 120,
          child: CustomPaint(painter: PulseChart(chronologicalPulse),
              child: const SizedBox.expand())),
      const Text('Точки соединены в порядке измерений; пропущенные значения пульса не выводятся.',
          style: TextStyle(fontSize: 12)),
      const SizedBox(height: 24),
      const Text('Личный ориентир', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
      const Text('Для демонстрации сравнения глюкозы натощак. Оставьте поле пустым, чтобы удалить ориентир.'),
      const SizedBox(height: 12),
      input('Верхняя граница, ммоль/л', target, hint: 'Например, 5,5'),
      FilledButton(onPressed: saveTarget, child: const Text('Сохранить ориентир')),
      const SizedBox(height: 20),
      const Text('Приложение хранит записи только на данном устройстве и не ставит диагноз.',
          style: TextStyle(fontSize: 12)),
    ]);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Мои измерения'), actions: [
      IconButton(onPressed: loadDemo, tooltip: 'Загрузить учебные данные',
          icon: const Icon(Icons.science_outlined)),
    ]),
    body: busy ? const Center(child: CircularProgressIndicator())
        : [inputTab(), historyTab(), overviewTab()][tab],
    bottomNavigationBar: NavigationBar(selectedIndex: tab,
      onDestinationSelected: (n) => setState(() => tab = n),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.add_circle_outline), label: 'Ввод'),
        NavigationDestination(icon: Icon(Icons.history), label: 'История'),
        NavigationDestination(icon: Icon(Icons.insights_outlined), label: 'Сводка'),
      ]),
  );
}
