import 'dart:convert';
import 'package:http/http.dart' as http;

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

/// 轉乘結果裡的一段:在 [boardStop] 上車,搭 [routeName]([area]),在 [alightStop] 下車
class TransferLeg {
  final String boardStop;
  final String alightStop;
  final String routeName;
  final int direction;
  final String area;
  final int stopSpan;

  TransferLeg({
    required this.boardStop,
    required this.alightStop,
    required this.routeName,
    required this.direction,
    required this.area,
    required this.stopSpan,
  });

  String get directionLabel => direction == 0 ? '去程' : '返程';
}

/// 一筆完整的轉乘路線(由數個 [TransferLeg] 串接而成)
class TransferRouteMatch {
  final List<TransferLeg> legs;

  TransferRouteMatch({required this.legs});

  int get transferCount => legs.length - 1;
}

/// 一次轉乘查詢的完整結果
class TransferSearchResult {
  final List<TransferRouteMatch> matches;
  final List<String> startSuggestions;
  final List<String> endSuggestions;
  final bool possiblyIncomplete;

  TransferSearchResult({
    required this.matches,
    required this.startSuggestions,
    required this.endSuggestions,
    required this.possiblyIncomplete,
  });
}

/// BFS 內部用:單一路線的站序清單(從 API 回傳的 route JSON 整理出來,只留需要的欄位)
class _RouteStops {
  final String area;
  final String routeName;
  final int direction;
  final List<_StopSeq> stops;

  _RouteStops({
    required this.area,
    required this.routeName,
    required this.direction,
    required this.stops,
  });
}

class _StopSeq {
  final String name;
  final int seq;
  _StopSeq(this.name, this.seq);
}

/// BFS 內部用:某一站被到達時的狀態,用 parent 指標串成完整路徑
class _Reached {
  final String stopName;
  final int legCount;
  final _RouteStops? viaRoute;
  final String? boardStop;
  final int? boardSeq;
  final int? alightSeq;
  final _Reached? parent;

  _Reached({
    required this.stopName,
    required this.legCount,
    this.viaRoute,
    this.boardStop,
    this.boardSeq,
    this.alightSeq,
    this.parent,
  });
}

/// 呼叫交通部 TDX 運輸資料流通服務 API 的服務類別
///
/// Token 透過後端 proxy(/api/token,見專案根目錄 api/token.js)取得,
/// TDX 的 Client ID / Secret 只存在後端環境變數,前端程式完全不會碰到金鑰。
class TdxService {
  static const String _proxyBase = 'https://bus-route-finder-zeta.vercel.app';
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

    final response = await http.get(Uri.parse('$_proxyBase/api/token'));

    if (response.statusCode != 200) {
      throw Exception('取得授權失敗(狀態碼 ${response.statusCode}),請確認後端 proxy 是否部署成功');
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

  /// 抓回使用者勾選的縣市(+可選的公路客運)的路線站序資料,合併成 (area, routes) 清單
  /// 直達查詢與轉乘查詢都靠這個共用的抓取邏輯,確保兩者查到的是同一批資料
  static Future<List<MapEntry<String, List<dynamic>>>> _fetchAllRouteEntries({
    required List<String> cityCodes,
    required bool includeInterCity,
  }) async {
    final token = await _getAccessToken();

    final cityFutures = cityCodes.map(
      (code) async => MapEntry(_allCities[code] ?? code, await _fetchCity(token, code)),
    );
    final futures = [
      ...cityFutures,
      if (includeInterCity) _fetchInterCity(token).then((data) => MapEntry('公路客運', data)),
    ];

    return Future.wait(futures);
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
    final results = await _fetchAllRouteEntries(
      cityCodes: cityCodes,
      includeInterCity: includeInterCity,
    );

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

  /// BFS 過程中最多展開幾個「站」,超過就提前停止並回報結果可能不完整(避免在手機/瀏覽器端卡死)
  static const int _maxTransferExpansions = 20000;

  /// 轉乘查詢每次回傳的結果上限(避免清單長到沒意義)
  static const int _maxTransferResults = 30;

  /// 查詢需要轉乘的公車路線,[minTransfers]/[maxTransfers] 決定要找幾次轉乘(1 次轉乘傳 1,1；多次轉乘傳 2,3)
  /// 演算法:把「在某站上車、搭同一條路線、在後面某站下車」視為一個 leg,BFS 逐輪展開,
  /// 直達 = 1 leg,轉乘 N 次 = N+1 legs。轉乘節點之間用精確站名比對,起訖站沿用現有的模糊(contains)比對。
  static Future<TransferSearchResult> findTransferRoutes({
    required List<String> cityCodes,
    required bool includeInterCity,
    required String startStation,
    required String endStation,
    required int minTransfers,
    required int maxTransfers,
  }) async {
    final entries = await _fetchAllRouteEntries(
      cityCodes: cityCodes,
      includeInterCity: includeInterCity,
    );

    final allStopNames = <String>{};
    final stopToRoutes = <String, List<MapEntry<_RouteStops, int>>>{};

    for (final entry in entries) {
      final area = entry.key;
      for (final route in entry.value) {
        final rawStops = route['Stops'] as List<dynamic>?;
        if (rawStops == null) continue;

        final stops = <_StopSeq>[];
        for (final stop in rawStops) {
          final name = stop['StopName']?['Zh_tw'] as String? ?? '';
          final seq = stop['StopSequence'] as int? ?? 0;
          if (name.isEmpty) continue;
          allStopNames.add(name);
          stops.add(_StopSeq(name, seq));
        }
        if (stops.isEmpty) continue;

        final routeStops = _RouteStops(
          area: area,
          routeName: route['RouteName']?['Zh_tw'] as String? ?? '未知路線',
          direction: route['Direction'] as int? ?? 0,
          stops: stops,
        );

        for (final stop in stops) {
          stopToRoutes.putIfAbsent(stop.name, () => []).add(MapEntry(routeStops, stop.seq));
        }
      }
    }

    final minLegs = minTransfers + 1;
    final maxLegs = maxTransfers + 1;

    final startNames = allStopNames.where((n) => n.contains(startStation)).toSet();
    final endNames = allStopNames.where((n) => n.contains(endStation)).toSet();

    final matches = <TransferRouteMatch>[];
    var possiblyIncomplete = false;

    if (startNames.isNotEmpty && endNames.isNotEmpty) {
      final visited = <String, _Reached>{};
      var frontier = <_Reached>[];

      for (final name in startNames) {
        final reached = _Reached(stopName: name, legCount: 0);
        visited[name] = reached;
        frontier.add(reached);
      }

      var expansions = 0;
      for (var leg = 1; leg <= maxLegs && frontier.isNotEmpty; leg++) {
        final nextFrontier = <_Reached>[];

        for (final current in frontier) {
          final routesHere = stopToRoutes[current.stopName];
          if (routesHere == null) continue;

          for (final routeEntry in routesHere) {
            final route = routeEntry.key;
            final boardSeq = routeEntry.value;

            // 不要「轉乘」到剛剛搭過來的同一條路線,那本來就該在更早的 leg 找到
            if (route == current.viaRoute) continue;

            for (final stop in route.stops) {
              if (stop.seq <= boardSeq) continue;
              if (visited.containsKey(stop.name)) continue;

              expansions++;
              if (expansions > _maxTransferExpansions) {
                possiblyIncomplete = true;
                break;
              }

              final reached = _Reached(
                stopName: stop.name,
                legCount: leg,
                viaRoute: route,
                boardStop: current.stopName,
                boardSeq: boardSeq,
                alightSeq: stop.seq,
                parent: current,
              );
              visited[stop.name] = reached;
              nextFrontier.add(reached);

              if (endNames.contains(stop.name) && leg >= minLegs && leg <= maxLegs) {
                matches.add(_buildTransferMatch(reached));
              }
            }
            if (possiblyIncomplete) break;
          }
          if (possiblyIncomplete) break;
        }

        if (possiblyIncomplete) break;
        frontier = nextFrontier;
      }
    }

    final dedup = <String>{};
    final deduped = <TransferRouteMatch>[];
    for (final match in matches) {
      final key = match.legs.map((l) => '${l.area}/${l.routeName}/${l.direction}').join('>');
      if (dedup.add(key)) deduped.add(match);
    }

    deduped.sort((a, b) {
      final legCompare = a.legs.length.compareTo(b.legs.length);
      if (legCompare != 0) return legCompare;
      return _totalSpan(a).compareTo(_totalSpan(b));
    });

    final limited = deduped.take(_maxTransferResults).toList();

    var startSuggestions = <String>[];
    var endSuggestions = <String>[];
    if (limited.isEmpty) {
      startSuggestions = _suggestSimilar(startStation, allStopNames);
      endSuggestions = _suggestSimilar(endStation, allStopNames);
    }

    return TransferSearchResult(
      matches: limited,
      startSuggestions: startSuggestions,
      endSuggestions: endSuggestions,
      possiblyIncomplete: possiblyIncomplete,
    );
  }

  /// 從 BFS 到達迄站的最終狀態,沿 parent 指標回溯組出完整的 leg 鏈
  static TransferRouteMatch _buildTransferMatch(_Reached end) {
    final legs = <TransferLeg>[];
    var current = end;
    while (current.parent != null) {
      legs.add(TransferLeg(
        boardStop: current.boardStop!,
        alightStop: current.stopName,
        routeName: current.viaRoute!.routeName,
        direction: current.viaRoute!.direction,
        area: current.viaRoute!.area,
        stopSpan: current.alightSeq! - current.boardSeq!,
      ));
      current = current.parent!;
    }
    return TransferRouteMatch(legs: legs.reversed.toList());
  }

  /// 粗略估計一筆轉乘路線的「總站數跨度」,當排序 tie-breaker 用(不是精確距離,只是概略指標)
  static int _totalSpan(TransferRouteMatch match) {
    return match.legs.fold(0, (sum, leg) => sum + leg.stopSpan);
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
