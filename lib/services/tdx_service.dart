import 'dart:convert';
import 'package:http/http.dart' as http;
import 'tdx_config.dart';

/// 一筆符合條件的公車路線比對結果
class RouteMatch {
  final String routeName;
  final int direction; // 0 = 去程, 1 = 返程
  final String area; // 行政區名稱,或「公路客運」

  RouteMatch({required this.routeName, required this.direction, required this.area});

  String get directionLabel => direction == 0 ? '去程' : '返程';
}

/// 一次查詢的完整結果:符合的路線,以及查無結果時的「你是不是要找」建議站名
class RouteSearchResult {
  final List<RouteMatch> matches;
  final List<String> startSuggestions;
  final List<String> endSuggestions;

  RouteSearchResult({
    required this.matches,
    required this.startSuggestions,
    required this.endSuggestions,
  });
}

/// 呼叫交通部 TDX 運輸資料流通服務 API 的服務類別
///
/// Client ID / Secret 放在 tdx_config.dart(不會被 Git 追蹤),
/// 範本見 tdx_config.example.dart。
class TdxService {
  static const String _authUrl =
      'https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token';
  static const String _apiBase = 'https://tdx.transportdata.tw/api/basic';

  // 公車路線常常跨縣市,所以查詢時把所有縣市的市公車,加上不分縣市的公路客運,全部一起查
  static const Map<String, String> _allCities = {
    'Taipei': '台北市',
    'NewTaipei': '新北市',
    'Taoyuan': '桃園市',
    'Taichung': '台中市',
    'Tainan': '台南市',
    'Kaohsiung': '高雄市',
    'Keelung': '基隆市',
    'Hsinchu': '新竹市',
    'HsinchuCounty': '新竹縣',
    'MiaoliCounty': '苗栗縣',
    'ChanghuaCounty': '彰化縣',
    'NantouCounty': '南投縣',
    'YunlinCounty': '雲林縣',
    'ChiayiCounty': '嘉義縣',
    'Chiayi': '嘉義市',
    'PingtungCounty': '屏東縣',
    'YilanCounty': '宜蘭縣',
    'HualienCounty': '花蓮縣',
    'TaitungCounty': '台東縣',
    'KinmenCounty': '金門縣',
    'PenghuCounty': '澎湖縣',
    'LienchiangCounty': '連江縣',
  };

  /// 給 UI 用來畫縣市勾選清單(代碼 → 中文名稱)
  static Map<String, String> get cityOptions => _allCities;

  static String? _cachedToken;
  static DateTime? _tokenExpiry;

  static Future<String> _getAccessToken() async {
    if (_cachedToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!)) {
      return _cachedToken!;
    }

    final response = await http.post(
      Uri.parse(_authUrl),
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'client_credentials',
        'client_id': TdxConfig.clientId,
        'client_secret': TdxConfig.clientSecret,
      },
    );

    if (response.statusCode != 200) {
      throw Exception('TDX 授權失敗(狀態碼 ${response.statusCode}),請確認 Client ID / Secret 是否正確');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    _cachedToken = data['access_token'] as String;
    final expiresIn = data['expires_in'] as int;
    _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn - 60));
    return _cachedToken!;
  }

  /// 抓某個縣市的市公車路線站序資料,失敗時回空清單(不讓單一縣市出錯擋住整體查詢)
  static Future<List<dynamic>> _fetchCity(String token, String cityCode) async {
    final uri = Uri.parse('$_apiBase/v2/Bus/StopOfRoute/City/$cityCode?\$format=JSON');
    final response = await http.get(uri, headers: {'authorization': 'Bearer $token'});
    if (response.statusCode != 200) return [];
    return jsonDecode(response.body) as List<dynamic>;
  }

  /// 抓公路客運(跨縣市)路線站序資料
  static Future<List<dynamic>> _fetchInterCity(String token) async {
    final uri = Uri.parse('$_apiBase/v2/Bus/StopOfRoute/InterCity?\$format=JSON');
    final response = await http.get(uri, headers: {'authorization': 'Bearer $token'});
    if (response.statusCode != 200) return [];
    return jsonDecode(response.body) as List<dynamic>;
  }

  /// 查詢有經過 [startStation] 且接著經過 [endStation] 的公車路線
  /// [cityCodes] 是要查詢的縣市代碼清單(只查使用者勾選的,平行發送請求後合併比對)
  /// [includeInterCity] 是否一併查公路客運(跨縣市,只有一個 API、不影響速度)
  static Future<RouteSearchResult> findRoutes({
    required List<String> cityCodes,
    required bool includeInterCity,
    required String startStation,
    required String endStation,
  }) async {
    final token = await _getAccessToken();

    final cityFutures = cityCodes.map(
      (code) async => MapEntry(_allCities[code] ?? code, await _fetchCity(token, code)),
    );
    final futures = [
      ...cityFutures,
      if (includeInterCity) _fetchInterCity(token).then((data) => MapEntry('公路客運', data)),
    ];

    final results = await Future.wait(futures);

    final matches = <RouteMatch>[];
    final allStopNames = <String>{};

    for (final entry in results) {
      final area = entry.key;
      for (final route in entry.value) {
        final stops = route['Stops'] as List<dynamic>?;
        if (stops == null) continue;

        int? startSeq;
        int? endSeq;

        for (final stop in stops) {
          final name = stop['StopName']?['Zh_tw'] as String? ?? '';
          allStopNames.add(name);
          final seq = stop['StopSequence'] as int? ?? 0;
          if (startSeq == null && name.contains(startStation)) startSeq = seq;
          if (endSeq == null && name.contains(endStation)) endSeq = seq;
        }

        // 起站跟迄站都有出現,且起站的站序在迄站之前,才算同方向、有效的路線
        if (startSeq != null && endSeq != null && startSeq < endSeq) {
          final routeName = route['RouteName']?['Zh_tw'] as String? ?? '未知路線';
          final direction = route['Direction'] as int? ?? 0;
          matches.add(RouteMatch(routeName: routeName, direction: direction, area: area));
        }
      }
    }

    var startSuggestions = <String>[];
    var endSuggestions = <String>[];
    if (matches.isEmpty) {
      startSuggestions = _suggestSimilar(startStation, allStopNames);
      endSuggestions = _suggestSimilar(endStation, allStopNames);
    }

    return RouteSearchResult(
      matches: matches,
      startSuggestions: startSuggestions,
      endSuggestions: endSuggestions,
    );
  }

  /// 從所有出現過的站名裡,找出跟 [query] 最相似的幾個,供「你是不是要找」使用
  static List<String> _suggestSimilar(String query, Set<String> names) {
    if (query.isEmpty) return [];

    final scored = names
        .map((name) => MapEntry(name, _similarity(query, name)))
        .where((e) => e.value > 0)
        .toList();
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(5).map((e) => e.key).toList();
  }

  /// 簡單相似度評分:互為子字串給高分,否則看共同字元數
  static int _similarity(String query, String name) {
    if (name == query) return 1000;
    if (name.contains(query) || query.contains(name)) return 100;

    var score = 0;
    for (final char in query.runes) {
      if (name.contains(String.fromCharCode(char))) score++;
    }
    return score;
  }
}
