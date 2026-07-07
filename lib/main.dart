import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
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

enum _SearchMode { direct, oneTransfer, multiTransfer }

class _BusQueryPageState extends State<BusQueryPage> {
  final _startController = TextEditingController();
  final _endController = TextEditingController();

  // 預設先勾雙北,使用者可以自己增減要查的縣市
  final Set<String> _selectedCities = {'Taipei', 'NewTaipei'};
  bool _includeInterCity = true;

  // 預設是直達查詢,跟新增轉乘功能前的行為完全一樣
  _SearchMode _mode = _SearchMode.direct;

  bool _isLoading = false;
  String? _errorMessage;
  List<RouteMatch> _results = [];
  List<String> _startSuggestions = [];
  List<String> _endSuggestions = [];

  // 轉乘查詢專用的狀態,跟上面直達查詢的狀態完全分開,兩種模式互不干擾
  bool _isTransferLoading = false;
  String? _transferErrorMessage;
  List<TransferRouteMatch> _transferResults = [];
  List<String> _transferStartSuggestions = [];
  List<String> _transferEndSuggestions = [];
  bool _transferPossiblyIncomplete = false;

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

  Future<void> _searchTransfer() async {
    final start = _startController.text.trim();
    final end = _endController.text.trim();

    if (start.isEmpty || end.isEmpty) {
      setState(() => _transferErrorMessage = '請輸入起站與迄站名稱');
      return;
    }

    if (_selectedCities.isEmpty && !_includeInterCity) {
      setState(() => _transferErrorMessage = '請至少勾選一個縣市,或勾選公路客運');
      return;
    }

    // 一次轉乘固定查 1 次轉乘;多次轉乘查 2~3 次轉乘(範圍越大越慢,設上限避免卡死)
    final minTransfers = _mode == _SearchMode.oneTransfer ? 1 : 2;
    final maxTransfers = _mode == _SearchMode.oneTransfer ? 1 : 3;

    setState(() {
      _isTransferLoading = true;
      _transferErrorMessage = null;
      _transferResults = [];
      _transferStartSuggestions = [];
      _transferEndSuggestions = [];
      _transferPossiblyIncomplete = false;
    });

    try {
      final result = await TdxService.findTransferRoutes(
        cityCodes: _selectedCities.toList(),
        includeInterCity: _includeInterCity,
        startStation: start,
        endStation: end,
        minTransfers: minTransfers,
        maxTransfers: maxTransfers,
      );
      setState(() {
        _transferResults = result.matches;
        _transferStartSuggestions = result.startSuggestions;
        _transferEndSuggestions = result.endSuggestions;
        _transferPossiblyIncomplete = result.possiblyIncomplete;
      });
    } catch (e) {
      setState(() => _transferErrorMessage = e.toString());
    } finally {
      setState(() => _isTransferLoading = false);
    }
  }

  Future<void> _runDiagnostics() async {
    final urls = {
      'Google': 'https://www.google.com',
      'TDX': 'https://tdx.transportdata.tw',
      'Vercel proxy': 'https://bus-route-finder-zeta.vercel.app/api/token',
    };

    final lines = <String>[];
    for (final entry in urls.entries) {
      try {
        final res = await http.get(Uri.parse(entry.value)).timeout(const Duration(seconds: 10));
        lines.add('${entry.key}: 成功 (狀態碼 ${res.statusCode})');
      } catch (e) {
        lines.add('${entry.key}: 失敗 — $e');
      }
    }

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('網路診斷結果'),
        content: Text(lines.join('\n\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('關閉')),
        ],
      ),
    );
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

  Widget _buildTransferResultTile(TransferRouteMatch match) {
    final parts = <String>[];
    for (var i = 0; i < match.legs.length; i++) {
      final leg = match.legs[i];
      if (i == 0) parts.add(leg.boardStop);
      parts.add('〔${leg.routeName} ${leg.directionLabel}〕');
      parts.add(leg.alightStop);
    }
    return ListTile(
      leading: const Icon(Icons.directions_bus),
      title: Text(parts.join(' → ')),
      subtitle: Text('${match.transferCount} 次轉乘'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final noResultsAtAll = !_isLoading &&
        _errorMessage == null &&
        _results.isEmpty &&
        _startSuggestions.isEmpty &&
        _endSuggestions.isEmpty;

    final noTransferResultsAtAll = !_isTransferLoading &&
        _transferErrorMessage == null &&
        _transferResults.isEmpty &&
        _transferStartSuggestions.isEmpty &&
        _transferEndSuggestions.isEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('公車起訖站查詢')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<_SearchMode>(
              segments: const [
                ButtonSegment(value: _SearchMode.direct, label: Text('直達')),
                ButtonSegment(value: _SearchMode.oneTransfer, label: Text('一次轉乘')),
                ButtonSegment(value: _SearchMode.multiTransfer, label: Text('多次轉乘')),
              ],
              selected: {_mode},
              onSelectionChanged: (selection) => setState(() => _mode = selection.first),
            ),
            const SizedBox(height: 12),
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
              onPressed: _isLoading || _isTransferLoading
                  ? null
                  : (_mode == _SearchMode.direct ? _search : _searchTransfer),
              child: const Text('查詢'),
            ),
            TextButton(
              onPressed: _runDiagnostics,
              child: const Text('網路診斷(暫時除錯用)'),
            ),
            const SizedBox(height: 16),
            if (_mode == _SearchMode.direct) ...[
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
              ..._results.map((route) => ListTile(
                    leading: const Icon(Icons.directions_bus),
                    title: Text(route.routeName),
                    subtitle: Text('${route.area} · ${route.directionLabel}'),
                  )),
            ] else ...[
              if (_isTransferLoading) ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 8),
                const Text('查詢中,轉乘查詢較耗時,請稍候...'),
              ],
              if (_transferErrorMessage != null)
                Text(_transferErrorMessage!, style: const TextStyle(color: Colors.red)),
              if (_mode == _SearchMode.multiTransfer)
                const Text('查詢範圍:最多 3 次轉乘', style: TextStyle(color: Colors.grey)),
              if (_transferPossiblyIncomplete)
                const Text('路網過大,結果可能不完整', style: TextStyle(color: Colors.orange)),
              if (noTransferResultsAtAll) const Text('輸入起訖站後按查詢,結果會列在這裡'),
              _buildSuggestionSection('起站', _transferStartSuggestions, _startController),
              _buildSuggestionSection('迄站', _transferEndSuggestions, _endController),
              ..._transferResults.map(_buildTransferResultTile),
            ],
          ],
        ),
      ),
    );
  }
}
