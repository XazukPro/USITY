import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../data/usity_api.dart';
import '../../design/catalog_card.dart';
import '../../theme/tokens.dart';

const _limit = 100 * 1024 * 1024;
const _extensions = [
  'pdf',
  'jpg',
  'jpeg',
  'png',
  'gif',
  'webp',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
];
typedef _Json = Map<String, dynamic>;

String _namespace(List<String> values) =>
    const Uuid().v5(Namespace.url.value, jsonEncode(values));
String _account(Uri base, String user) => _namespace([base.toString(), user]);

class _Catalog {
  _Catalog(this.items, this.categories);
  final List<_Json> items;
  final List<String> categories;
  factory _Catalog.parse(_Json data) => _Catalog(
    (data['items'] as List).cast<_Json>(),
    (data['categories'] as List).cast<String>(),
  );

  _Json get published => {
    'items': items.where((i) => i['status'] == 'published').toList(),
    'categories': categories,
  };
}

// Serialize local critical sections, including logout. Network transfers run
// outside this queue. A retired session cannot recreate files after a purge.
Future<void> _disk = Future.value();
Future<T> _onDisk<T>(Future<T> Function() action) {
  final result = _disk.then((_) => action());
  _disk = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  return result;
}

final _generations = <String, int>{};
Future<Directory> _root(String account, {required bool viewer}) async {
  final root = viewer
      ? await getTemporaryDirectory()
      : await getApplicationSupportDirectory();
  return Directory('${root.path}/usity-materials/$account');
}

Future<void> _remove(FileSystemEntity entry) async {
  if (await entry.exists()) await entry.delete(recursive: entry is Directory);
}

class _MaterialCache {
  _MaterialCache(this.account, String group)
    : groupKey = _namespace([group]),
      generation = _generations[account] ?? 0;
  final String account, groupKey;
  final int generation;
  bool retired = false;
  bool get active => !retired && generation == (_generations[account] ?? 0);

  void check() {
    if (!active) throw const ApiException(401, 'Сессия закрыта.');
  }

  Future<Directory> directory({bool viewer = false}) async {
    final root = await _root(account, viewer: viewer);
    return Directory('${root.path}/$groupKey');
  }

  Future<T> _db<T>(Future<T> Function(Database) use) async {
    check();
    final dir = await (await directory()).create(recursive: true);
    final db = await openDatabase(
      '${dir.path}/catalog.db',
      singleInstance: false,
      version: 1,
      onCreate: (db, _) => db.execute(
        'CREATE TABLE catalog (id INTEGER PRIMARY KEY, data TEXT NOT NULL)',
      ),
    );
    try {
      return await use(db);
    } finally {
      await db.close();
    }
  }

  Future<_Catalog?> read() => _onDisk(
    () => _db((db) async {
      final rows = await db.query('catalog', limit: 1);
      return rows.isEmpty
          ? null
          : _Catalog.parse(jsonDecode(rows.single['data'] as String));
    }),
  );

  Future<void> save(_Catalog catalog) => _onDisk(() async {
    await _db(
      (db) => db.insert('catalog', {
        'id': 1,
        'data': jsonEncode(catalog.published),
      }, conflictAlgorithm: ConflictAlgorithm.replace),
    );
    final visible = catalog.items
        .where((r) => r['status'] != 'rejected' && r['filename'] != null)
        .map((r) => r['id'])
        .toSet();
    for (final viewer in [false, true]) {
      final dir = await directory(viewer: viewer);
      if (!await dir.exists()) continue;
      await for (final file in dir.list(followLinks: false)) {
        final name = file.uri.pathSegments.last;
        if (RegExp(r'^[0-9a-f]{32}\.').hasMatch(name) &&
            !visible.contains(name.split('.').first)) {
          await _remove(file);
        }
        if (name.startsWith('part-') &&
            (await file.stat()).modified.isBefore(
              DateTime.now().subtract(const Duration(days: 1)),
            )) {
          await _remove(file);
        }
      }
    }
  });

  Future<void> clear() => _onDisk(() async {
    if (!active) return;
    for (final viewer in [false, true]) {
      await _remove(await directory(viewer: viewer));
    }
  });

  Future<File> file(_Json row, {bool viewer = false}) async {
    final id = row['id'] as String;
    final ext = (row['filename'] as String).split('.').last.toLowerCase();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id) || !_extensions.contains(ext)) {
      throw const FormatException('file');
    }
    final dir = await directory(viewer: viewer);
    return File('${dir.path}/$id.$ext');
  }

  Future<File> stage() => _onDisk(() async {
    check();
    final dir = await (await directory()).create(recursive: true);
    return File('${dir.path}/part-${const Uuid().v4()}')
        .create(exclusive: true);
  });

  Future<void> forget(_Json row) => _onDisk(() async {
    check();
    await _db((db) async {
      final records = await db.query('catalog', limit: 1);
      if (records.isEmpty) return;
      final snapshot = _Catalog.parse(
        jsonDecode(records.single['data'] as String),
      );
      snapshot.items.removeWhere((i) => i['id'] == row['id']);
      await db.update('catalog', {
        'data': jsonEncode(snapshot.published),
      }, where: 'id=1');
    });
    if (row['filename'] != null) {
      for (final viewer in [false, true]) {
        await _remove(await file(row, viewer: viewer));
      }
    }
  });
}

class _UploadRequest extends http.BaseRequest {
  _UploadRequest(super.method, super.url, this.file);
  final PlatformFile file;
  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(file.readAsByteStream());
  }
}

class LiveMaterials extends StatefulWidget {
  const LiveMaterials({
    super.key,
    required this.api,
    required this.groupId,
    required this.canReview,
    required this.subjects,
    required this.userId,
    this.initialSubject,
  });
  final UsityApi api;
  final String groupId, userId;
  final bool canReview;
  final List<String> subjects;
  final String? initialSubject;

  static Future<void> purgeCache(Uri base, String userId) {
    final account = _account(base, userId);
    _generations[account] = (_generations[account] ?? 0) + 1;
    return _onDisk(() async {
      for (final viewer in [false, true]) {
        await _remove(await _root(account, viewer: viewer));
      }
    });
  }

  @override
  State<LiveMaterials> createState() => _LiveMaterialsState();
}

class _LiveMaterialsState extends State<LiveMaterials>
    with WidgetsBindingObserver {
  late _MaterialCache cache;
  int revision = 0;
  bool loading = true, offline = false, busy = false;
  String? message, subject;
  String scope = 'group', search = '';
  _Catalog? catalog;
  final searchField = TextEditingController();
  String get path => '/groups/${Uri.encodeComponent(widget.groupId)}/materials';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    reset();
  }

  void reset() {
    cache = _MaterialCache(
      _account(widget.api.base, widget.userId),
      widget.groupId,
    );
    catalog = null;
    message = null;
    searchField.clear();
    search = '';
    subject = widget.initialSubject;
    scope = 'group';
    busy = false;
    refresh();
  }

  @override
  void didUpdateWidget(LiveMaterials old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api ||
        old.groupId != widget.groupId ||
        old.userId != widget.userId ||
        old.canReview != widget.canReview) {
      cache.retired = true;
      reset();
    } else if (old.initialSubject != widget.initialSubject) {
      subject = widget.initialSubject;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  @override
  void dispose() {
    cache.retired = true;
    WidgetsBinding.instance.removeObserver(this);
    searchField.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    final current = cache;
    final request = ++revision;
    bool valid() => mounted && current.active && revision == request;
    setState(() {
      loading = true;
      message = null;
    });
    try {
      final data = _Catalog.parse(await widget.api.request('GET', path));
      if (!valid()) return;
      setState(() {
        catalog = data;
        offline = false;
      });
      try {
        await current.save(data);
      } on Exception {
        if (valid()) {
          setState(
            () =>
                message = 'Не удалось сохранить каталог для офлайн-просмотра.',
          );
        }
      }
    } on ApiException catch (e) {
      if (!valid()) return;
      if (e.status == 401 || e.status == 403 || e.status == 404) {
        setState(() {
          catalog = null;
          offline = false;
          message = e.message;
        });
        await current.clear();
      } else if (e.status == 0) {
        _Catalog? saved;
        try {
          saved = await current.read();
        } on Exception {
          /* Storage unavailable. */
        }
        if (valid()) {
          setState(() {
            catalog = saved;
            offline = true;
            message = saved == null
                ? 'Нет соединения. Сохранённый каталог пока пуст.'
                : 'Офлайн · сохранённый каталог';
          });
        }
      } else {
        setState(() => message = e.message);
      }
    } finally {
      if (valid()) setState(() => loading = false);
    }
  }

  void notify(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  bool visible(_Json row) =>
      catalog?.items.any(
        (i) => i['id'] == row['id'] && i['status'] != 'rejected',
      ) ??
      false;

  Future<void> act(Future<void> Function() action, {_Json? item}) async {
    if (busy) return;
    final current = cache;
    setState(() => busy = true);
    try {
      await action();
    } on ApiException catch (e) {
      if (!mounted || !current.active) return;
      if (e.status == 401 || e.status == 403 || e.status == 404) {
        ++revision;
        if (item != null && e.status != 401) {
          setState(
            () => catalog?.items.removeWhere((i) => i['id'] == item['id']),
          );
          await current.forget(item);
        } else {
          setState(() => catalog = null);
          await current.clear();
        }
        if (mounted && current.active) await refresh();
      } else if (e.status == 409) {
        await refresh();
      }
      if (current.active) {
        notify(e.detail is String ? e.detail as String : e.message);
      }
    } on Exception {
      if (current.active) {
        notify('Не удалось выполнить действие. Повторите попытку.');
      }
    } finally {
      if (mounted && current.active) setState(() => busy = false);
    }
  }

  Future<void> openItem(_Json row) async {
    final current = cache;
    if (row['status'] == 'rejected') return;
    if (row['url'] != null) {
      final uri = Uri.tryParse(row['url'] as String);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        notify('Не удалось открыть ссылку.');
      }
      return;
    }
    final saved = await current.file(row);
    final hasFile = await saved.exists() && await saved.length() == row['size'];
    final api = widget.api;
    final route = api.base.resolve(
      '$path/${Uri.encodeComponent(row['id'])}/download',
    );
    final request = http.Request(hasFile ? 'HEAD' : 'GET', route)
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer ${api.token}';
    try {
      final response = await api.client
          .send(request)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw ApiException(response.statusCode, 'Файл недоступен.');
      }
      if (hasFile) {
        await response.stream.drain<void>();
      } else {
        final part = await current.stage();
        try {
          final sink = await part.open(mode: FileMode.write);
          var received = 0;
          try {
            await for (final data in response.stream.timeout(
              const Duration(seconds: 30),
            )) {
              current.check();
              received += data.length;
              if (received > _limit || received > (row['size'] as int)) {
                throw const FormatException('size');
              }
              await sink.writeFrom(data);
            }
          } finally {
            await sink.close();
          }
          if (received != row['size']) throw const FormatException('length');
          await _onDisk(() async {
            current.check();
            if (visible(row)) await part.rename(saved.path);
          });
        } finally {
          await _remove(part);
        }
      }
    } on Exception catch (e) {
      final networkError =
          e is TimeoutException ||
          e is http.ClientException ||
          e is SocketException;
      if (!networkError) rethrow;
      if (!hasFile || row['status'] != 'published') {
        throw const ApiException(0, 'Файл недоступен без соединения.');
      }
    }
    // Android's FileProvider only grants read access under cache/usity-materials.
    await _onDisk(() async {
      current.check();
      if (!visible(row)) return;
      final viewer = await current.file(row, viewer: true);
      await viewer.parent.create(recursive: true);
      await saved.copy(viewer.path);
      current.check();
      final result = await OpenFilex.open(
        viewer.path,
        type: row['mime'] as String,
      );
      if (result.type != ResultType.done) {
        notify('На устройстве не удалось открыть файл.');
      }
    });
  }

  Future<void> edit() async {
    final current = cache, api = widget.api, route = path;
    final data = catalog;
    if (data == null || offline) return;
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _AddMaterial(
          api: api,
          path: route,
          scope: scope,
          canReview: widget.canReview,
          categories: data.categories,
          subjects: widget.subjects,
          initialSubject: subject,
        ),
      ),
    );
    if (mounted && current.active && created == true) await refresh();
  }

  Future<void> addCategory() async {
    var name = '';
    final current = cache;
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новая категория'),
        content: TextField(
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Название'),
          onChanged: (s) => name = s.trim(),
          onSubmitted: (s) => Navigator.pop(ctx, s.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, name),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (!current.active || value == null || value.isEmpty) return;
    await act(() async {
      await widget.api.request('POST', '$path/categories', {'name': value});
      if (current.active) await refresh();
    });
  }

  Future<void> decide(_Json row, String decision) => act(() async {
    final current = cache;
    await widget.api.request('POST', '$path/${row['id']}/decision', {
      'action': decision,
    });
    if (current.active) await refresh();
  }, item: row);

  Future<void> deleteItem(_Json row) async {
    final current = cache;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить материал?'),
        content: Text(row['title']),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (!current.active || confirmed != true) return;
    await act(() async {
      await widget.api.request('DELETE', '$path/${row['id']}');
      if (current.active) {
        await current.forget(row);
        await refresh();
      }
    }, item: row);
  }

  Widget tile(_Json row) {
    final p = Palette.of(context);
    final pending = row['status'] == 'pending',
        rejected = row['status'] == 'rejected';
    final link = row['url'] != null;
    final tags = (row['subjects'] as List).cast<String>();
    final subtitle = [
      link
          ? 'Ссылка'
          : (row['filename'] as String).split('.').last.toUpperCase(),
      row['category'],
      ...tags,
    ].join(' · ');
    final manage =
        !offline && !busy && (scope == 'personal' || widget.canReview);
    return CatalogCard(
      title: row['title'],
      subtitle: subtitle,
      warning: pending
          ? 'На проверке'
          : rejected
          ? 'Отклонено'
          : null,
      icon: link ? Icons.link : Icons.description_outlined,
      tint: p.lectureTint,
      iconColor: p.lectureInk,
      onTap: () {
        if (!rejected) act(() => openItem(row), item: row);
      },
      trailing: manage
          ? PopupMenuButton<String>(
              tooltip: 'Действия с материалом',
              onSelected: (s) {
                if (s == 'delete') {
                  deleteItem(row);
                } else {
                  decide(row, s);
                }
              },
              itemBuilder: (_) => [
                if (pending && widget.canReview) ...const [
                  PopupMenuItem(value: 'approve', child: Text('Опубликовать')),
                  PopupMenuItem(value: 'reject', child: Text('Отклонить')),
                ],
                const PopupMenuItem(value: 'delete', child: Text('Удалить')),
              ],
            )
          : Icon(Icons.chevron_right, color: p.inkMuted),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = catalog;
    final subjects = <String>{...widget.subjects, ?subject};
    final groups = <String, List<_Json>>{};
    for (final row in data?.items ?? <_Json>[]) {
      final labels = (row['subjects'] as List).cast<String>();
      subjects.addAll(labels);
      if (row['scope'] != scope ||
          (subject != null && !labels.contains(subject))) {
        continue;
      }
      if (![
        row['title'],
        row['category'],
        ...labels,
      ].join(' ').toLowerCase().contains(search)) {
        continue;
      }
      (groups[row['category']] ??= []).add(row);
    }
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Материалы', style: TypeScale.titleLg),
        actions: [
          if (widget.canReview && data != null)
            IconButton(
              tooltip: 'Добавить категорию',
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: offline || busy ? null : addCategory,
            ),
          IconButton(
            tooltip: 'Обновить каталог',
            onPressed: loading ? null : refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: data == null || offline
          ? null
          : FloatingActionButton(
              tooltip: 'Добавить материал',
              onPressed: busy ? null : edit,
              child: const Icon(Icons.add),
            ),
      body: SafeArea(
        child: Column(
          children: [
            if (loading || busy) const LinearProgressIndicator(),
            if (message != null)
              Padding(
                padding: const EdgeInsets.all(Metrics.space2),
                child: Text(message!, textAlign: TextAlign.center),
              ),
            if (data != null) ...[
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'group', label: Text('Групповые')),
                  ButtonSegment(value: 'personal', label: Text('Личные')),
                ],
                selected: {scope},
                onSelectionChanged: (s) => setState(() => scope = s.first),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Metrics.space5,
                  vertical: Metrics.space2,
                ),
                child: TextField(
                  controller: searchField,
                  decoration: InputDecoration(
                    hintText: 'Поиск по материалам',
                    filled: true,
                    fillColor: p.surfaceMuted,
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Metrics.radiusMd),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (s) =>
                      setState(() => search = s.trim().toLowerCase()),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Metrics.space5,
                  ),
                  child: Row(
                    children: [
                      for (final s in <String?>[null, ...subjects])
                        Padding(
                          padding: const EdgeInsets.only(right: Metrics.space2),
                          child: ChoiceChip(
                            label: Text(s ?? 'Все'),
                            selected: subject == s,
                            showCheckmark: false,
                            onSelected: (_) => setState(() => subject = s),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: refresh,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(
                      Metrics.space5,
                      0,
                      Metrics.space5,
                      86,
                    ),
                    children: [
                      if (groups.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: Text('Материалы не найдены')),
                        ),
                      for (final group in groups.entries) ...[
                        SectionCaption(group.key),
                        ...group.value.map(tile),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AddMaterial extends StatefulWidget {
  const _AddMaterial({
    required this.api,
    required this.path,
    required this.scope,
    required this.canReview,
    required this.categories,
    required this.subjects,
    this.initialSubject,
  });
  final UsityApi api;
  final String path, scope;
  final bool canReview;
  final List<String> categories, subjects;
  final String? initialSubject;
  @override
  State<_AddMaterial> createState() => _AddMaterialState();
}

class _AddMaterialState extends State<_AddMaterial> {
  final titleField = TextEditingController(),
      urlField = TextEditingController();
  final selected = <String>{};
  late String category;
  bool fileMode = false, saving = false;
  PlatformFile? file;
  String? error;
  @override
  void initState() {
    super.initState();
    category = widget.categories.contains('Ссылки')
        ? 'Ссылки'
        : widget.categories.first;
    if (widget.subjects.contains(widget.initialSubject)) {
      selected.add(widget.initialSubject!);
    }
  }

  @override
  void dispose() {
    titleField.dispose();
    urlField.dispose();
    super.dispose();
  }

  Future<void> pick() async {
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: _extensions,
      );
      if (picked == null || !mounted) return;
      final length = await picked.length();
      if (!mounted) return;
      if (length != null && (length <= 0 || length > _limit)) {
        setState(() => error = 'Выберите непустой файл до 100 МБ.');
        return;
      }
      setState(() {
        file = picked;
        error = null;
        if (titleField.text.isEmpty) titleField.text = picked.name;
      });
    } on Exception {
      if (mounted) setState(() => error = 'Не удалось выбрать файл.');
    }
  }

  Future<void> upload(PlatformFile picked, _Json metadata) async {
    final length = await picked.length();
    final request =
        _UploadRequest(
            'POST',
            widget.api.base.resolve('${widget.path}/files'),
            picked,
          )
          ..contentLength = length
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer ${widget.api.token}',
            'Content-Type': 'application/octet-stream',
            'X-Material-Metadata': base64Url.encode(
              utf8.encode(jsonEncode({...metadata, 'filename': picked.name})),
            ),
          });
    final response = await widget.api.client
        .send(request)
        .timeout(const Duration(minutes: 5));
    await response.stream.drain<void>().timeout(const Duration(seconds: 15));
    if (response.statusCode != 201) {
      throw ApiException(response.statusCode, switch (response.statusCode) {
        413 => 'Файл превышает 100 МБ.',
        422 => 'Проверьте формат файла, категорию и предметы.',
        401 || 403 => 'Недостаточно прав для загрузки.',
        _ => 'Не удалось загрузить файл.',
      });
    }
  }

  Future<void> submit() async {
    final title = titleField.text.trim();
    final uri = Uri.tryParse(urlField.text.trim());
    if (title.isEmpty ||
        (fileMode
            ? file == null
            : uri == null ||
                  uri.scheme != 'https' ||
                  uri.host.isEmpty ||
                  uri.userInfo.isNotEmpty)) {
      setState(
        () => error =
            'Введите название и ${fileMode ? 'выберите файл' : 'укажите HTTPS-ссылку'}.',
      );
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    final meta = {
      'title': title,
      'scope': widget.scope,
      'category': category,
      'subjects': selected.toList(),
    };
    try {
      if (fileMode) {
        await upload(file!, meta);
      } else {
        await widget.api.request('POST', '${widget.path}/links', {
          ...meta,
          'url': uri.toString(),
        });
      }
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(
          () => error = e.detail is String ? e.detail as String : e.message,
        );
      }
    } on Exception {
      if (mounted) {
        setState(
          () => error =
              'Связь прервалась. Обновите каталог, чтобы проверить результат.',
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.scope == 'group' && !widget.canReview;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.scope == 'personal' ? 'Личный материал' : 'Материал группы',
        ),
      ),
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: saving,
          child: ListView(
            padding: const EdgeInsets.all(Metrics.space5),
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Ссылка')),
                  ButtonSegment(value: true, label: Text('Файл')),
                ],
                selected: {fileMode},
                onSelectionChanged: (s) => setState(() {
                  fileMode = s.first;
                  error = null;
                  if (category == 'Ссылки' && fileMode) category = 'Другое';
                  if (category == 'Другое' && !fileMode) category = 'Ссылки';
                }),
              ),
              const SizedBox(height: Metrics.space4),
              TextField(
                controller: titleField,
                maxLength: 200,
                decoration: const InputDecoration(labelText: 'Название'),
              ),
              if (fileMode)
                OutlinedButton.icon(
                  onPressed: pick,
                  icon: const Icon(Icons.attach_file),
                  label: Text(file?.name ?? 'Выбрать файл до 100 МБ'),
                )
              else
                TextField(
                  controller: urlField,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'HTTPS-ссылка'),
                ),
              const SizedBox(height: Metrics.space4),
              DropdownButtonFormField<String>(
                initialValue: category,
                key: ValueKey(category),
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Категория'),
                items: [
                  for (final c in widget.categories)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (c) => setState(() => category = c!),
              ),
              if (widget.subjects.isNotEmpty) ...[
                const SectionCaption('Предметы'),
                Wrap(
                  spacing: Metrics.space2,
                  children: [
                    for (final s in widget.subjects.toSet())
                      FilterChip(
                        label: Text(s),
                        selected: selected.contains(s),
                        onSelected: (v) => setState(() {
                          if (v) {
                            selected.add(s);
                          } else {
                            selected.remove(s);
                          }
                        }),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: Metrics.space5),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Palette.of(context).dangerInk),
                ),
              FilledButton(
                onPressed: saving ? null : submit,
                child: Text(pending ? 'Предложить на проверку' : 'Сохранить'),
              ),
              if (saving) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}
