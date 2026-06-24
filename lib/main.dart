import 'package:flutter/material.dart';
import 'services/tdx_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '公車起訖站查詢',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: const BusQueryPage(),
    );
  }
}

class BusQueryPage extends StatefulWidget {
  const BusQueryPage({super.key});

  @override
  State<BusQueryPage> createState() => _BusQueryPageState();
}

class _BusQueryPageState extends State<BusQueryPage> {
  final _startController = TextEditingController();
  final _endController = TextEditingController();

  // 預設先勾雙北,使用者可以自己增減要查的縣市
  final Set<String> _selectedCities = {'Taipei', 'NewTaipei'};
  bool _includeInterCity = true;

  bool _isLoading = false;
  String? _errorMessage;
  List<RouteMatch> _results = [];
  List<String> _startSuggestions = [];
  List<String> _endSuggestions = [];

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final start = _startController.text.trim();
    final end = _endController.text.trim();

    if (start.isEmpty || end.isEmpty) {
      setState(() => _errorMessage = '請輸入起站與迄站名稱');
      return;
    }

    if (_selectedCities.isEmpty && !_includeInterCity) {
      setState(() => _errorMessage = '請至少勾選一個縣市,或勾選公路客運');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _results = [];
      _startSuggestions = [];
      _endSuggestions = [];
    });

    try {
      final result = await TdxService.findRoutes(
        cityCodes: _selectedCities.toList(),
        includeInterCity: _includeInterCity,
        startStation: start,
        endStation: end,
      );
      setState(() {
        _results = result.matches;
        _startSuggestions = result.startSuggestions;
        _endSuggestions = result.endSuggestions;
      });
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Widget _buildSuggestionSection(String label, List<String> suggestions, TextEditingController controller) {
    if (suggestions.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('找不到「${controller.text}」,你是不是要找「$label」:'),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: suggestions
              .map((s) => ActionChip(
                    label: Text(s),
                    onPressed: () => setState(() => controller.text = s),
                  ))
              .toList(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final noResultsAtAll = !_isLoading &&
        _errorMessage == null &&
        _results.isEmpty &&
        _startSuggestions.isEmpty &&
        _endSuggestions.isEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('公車起訖站查詢')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('查詢範圍(可多選,起訖站若跨縣市請都勾選)'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 0,
              children: [
                FilterChip(
                  label: const Text('公路客運'),
                  selected: _includeInterCity,
                  onSelected: (selected) => setState(() => _includeInterCity = selected),
                ),
                ...TdxService.cityOptions.entries.map((entry) {
                  final selected = _selectedCities.contains(entry.key);
                  return FilterChip(
                    label: Text(entry.value),
                    selected: selected,
                    onSelected: (value) => setState(() {
                      if (value) {
                        _selectedCities.add(entry.key);
                      } else {
                        _selectedCities.remove(entry.key);
                      }
                    }),
                  );
                }),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _startController,
              decoration: const InputDecoration(labelText: '起站名稱', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _endController,
              decoration: const InputDecoration(labelText: '迄站名稱', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isLoading ? null : _search,
              child: const Text('查詢'),
            ),
            const SizedBox(height: 16),
            if (_isLoading) ...[
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 8),
              const Text('查詢中,請稍候...'),
            ],
            if (_errorMessage != null)
              Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
            if (noResultsAtAll) const Text('輸入起訖站後按查詢,結果會列在這裡'),
            _buildSuggestionSection('起站', _startSuggestions, _startController),
            _buildSuggestionSection('迄站', _endSuggestions, _endController),
            Expanded(
              child: ListView.builder(
                itemCount: _results.length,
                itemBuilder: (context, index) {
                  final route = _results[index];
                  return ListTile(
                    leading: const Icon(Icons.directions_bus),
                    title: Text(route.routeName),
                    subtitle: Text('${route.area} · ${route.directionLabel}'),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
