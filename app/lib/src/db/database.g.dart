// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $NotesTable extends Notes with TableInfo<$NotesTable, Note> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $NotesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _noteIdMeta = const VerificationMeta('noteId');
  @override
  late final GeneratedColumn<String> noteId = GeneratedColumn<String>(
    'note_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _excerptMeta = const VerificationMeta(
    'excerpt',
  );
  @override
  late final GeneratedColumn<String> excerpt = GeneratedColumn<String>(
    'excerpt',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionVectorMeta = const VerificationMeta(
    'versionVector',
  );
  @override
  late final GeneratedColumn<String> versionVector = GeneratedColumn<String>(
    'version_vector',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentHashMeta = const VerificationMeta(
    'contentHash',
  );
  @override
  late final GeneratedColumn<String> contentHash = GeneratedColumn<String>(
    'content_hash',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _imageHashesMeta = const VerificationMeta(
    'imageHashes',
  );
  @override
  late final GeneratedColumn<String> imageHashes = GeneratedColumn<String>(
    'image_hashes',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isDeletedMeta = const VerificationMeta(
    'isDeleted',
  );
  @override
  late final GeneratedColumn<bool> isDeleted = GeneratedColumn<bool>(
    'is_deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_deleted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    noteId,
    title,
    content,
    excerpt,
    versionVector,
    contentHash,
    imageHashes,
    isDeleted,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'notes';
  @override
  VerificationContext validateIntegrity(
    Insertable<Note> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('note_id')) {
      context.handle(
        _noteIdMeta,
        noteId.isAcceptableOrUnknown(data['note_id']!, _noteIdMeta),
      );
    } else if (isInserting) {
      context.missing(_noteIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('excerpt')) {
      context.handle(
        _excerptMeta,
        excerpt.isAcceptableOrUnknown(data['excerpt']!, _excerptMeta),
      );
    } else if (isInserting) {
      context.missing(_excerptMeta);
    }
    if (data.containsKey('version_vector')) {
      context.handle(
        _versionVectorMeta,
        versionVector.isAcceptableOrUnknown(
          data['version_vector']!,
          _versionVectorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_versionVectorMeta);
    }
    if (data.containsKey('content_hash')) {
      context.handle(
        _contentHashMeta,
        contentHash.isAcceptableOrUnknown(
          data['content_hash']!,
          _contentHashMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_contentHashMeta);
    }
    if (data.containsKey('image_hashes')) {
      context.handle(
        _imageHashesMeta,
        imageHashes.isAcceptableOrUnknown(
          data['image_hashes']!,
          _imageHashesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_imageHashesMeta);
    }
    if (data.containsKey('is_deleted')) {
      context.handle(
        _isDeletedMeta,
        isDeleted.isAcceptableOrUnknown(data['is_deleted']!, _isDeletedMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {noteId};
  @override
  Note map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Note(
      noteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      excerpt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}excerpt'],
      )!,
      versionVector: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}version_vector'],
      )!,
      contentHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_hash'],
      )!,
      imageHashes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}image_hashes'],
      )!,
      isDeleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_deleted'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $NotesTable createAlias(String alias) {
    return $NotesTable(attachedDatabase, alias);
  }
}

class Note extends DataClass implements Insertable<Note> {
  /// note_id 主键（UUID）。
  final String noteId;
  final String title;

  /// Markdown 全文（新增）。
  final String content;
  final String excerpt;

  /// 版本向量 JSON（新增，替代单一 version int）。
  final String versionVector;

  /// SHA-256(content)（新增）。
  final String contentHash;

  /// JSON 数组（新增）。
  final String imageHashes;
  final bool isDeleted;
  final int createdAt;
  final int updatedAt;
  const Note({
    required this.noteId,
    required this.title,
    required this.content,
    required this.excerpt,
    required this.versionVector,
    required this.contentHash,
    required this.imageHashes,
    required this.isDeleted,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['note_id'] = Variable<String>(noteId);
    map['title'] = Variable<String>(title);
    map['content'] = Variable<String>(content);
    map['excerpt'] = Variable<String>(excerpt);
    map['version_vector'] = Variable<String>(versionVector);
    map['content_hash'] = Variable<String>(contentHash);
    map['image_hashes'] = Variable<String>(imageHashes);
    map['is_deleted'] = Variable<bool>(isDeleted);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  NotesCompanion toCompanion(bool nullToAbsent) {
    return NotesCompanion(
      noteId: Value(noteId),
      title: Value(title),
      content: Value(content),
      excerpt: Value(excerpt),
      versionVector: Value(versionVector),
      contentHash: Value(contentHash),
      imageHashes: Value(imageHashes),
      isDeleted: Value(isDeleted),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory Note.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Note(
      noteId: serializer.fromJson<String>(json['noteId']),
      title: serializer.fromJson<String>(json['title']),
      content: serializer.fromJson<String>(json['content']),
      excerpt: serializer.fromJson<String>(json['excerpt']),
      versionVector: serializer.fromJson<String>(json['versionVector']),
      contentHash: serializer.fromJson<String>(json['contentHash']),
      imageHashes: serializer.fromJson<String>(json['imageHashes']),
      isDeleted: serializer.fromJson<bool>(json['isDeleted']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'noteId': serializer.toJson<String>(noteId),
      'title': serializer.toJson<String>(title),
      'content': serializer.toJson<String>(content),
      'excerpt': serializer.toJson<String>(excerpt),
      'versionVector': serializer.toJson<String>(versionVector),
      'contentHash': serializer.toJson<String>(contentHash),
      'imageHashes': serializer.toJson<String>(imageHashes),
      'isDeleted': serializer.toJson<bool>(isDeleted),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  Note copyWith({
    String? noteId,
    String? title,
    String? content,
    String? excerpt,
    String? versionVector,
    String? contentHash,
    String? imageHashes,
    bool? isDeleted,
    int? createdAt,
    int? updatedAt,
  }) => Note(
    noteId: noteId ?? this.noteId,
    title: title ?? this.title,
    content: content ?? this.content,
    excerpt: excerpt ?? this.excerpt,
    versionVector: versionVector ?? this.versionVector,
    contentHash: contentHash ?? this.contentHash,
    imageHashes: imageHashes ?? this.imageHashes,
    isDeleted: isDeleted ?? this.isDeleted,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  Note copyWithCompanion(NotesCompanion data) {
    return Note(
      noteId: data.noteId.present ? data.noteId.value : this.noteId,
      title: data.title.present ? data.title.value : this.title,
      content: data.content.present ? data.content.value : this.content,
      excerpt: data.excerpt.present ? data.excerpt.value : this.excerpt,
      versionVector: data.versionVector.present
          ? data.versionVector.value
          : this.versionVector,
      contentHash: data.contentHash.present
          ? data.contentHash.value
          : this.contentHash,
      imageHashes: data.imageHashes.present
          ? data.imageHashes.value
          : this.imageHashes,
      isDeleted: data.isDeleted.present ? data.isDeleted.value : this.isDeleted,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Note(')
          ..write('noteId: $noteId, ')
          ..write('title: $title, ')
          ..write('content: $content, ')
          ..write('excerpt: $excerpt, ')
          ..write('versionVector: $versionVector, ')
          ..write('contentHash: $contentHash, ')
          ..write('imageHashes: $imageHashes, ')
          ..write('isDeleted: $isDeleted, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    noteId,
    title,
    content,
    excerpt,
    versionVector,
    contentHash,
    imageHashes,
    isDeleted,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Note &&
          other.noteId == this.noteId &&
          other.title == this.title &&
          other.content == this.content &&
          other.excerpt == this.excerpt &&
          other.versionVector == this.versionVector &&
          other.contentHash == this.contentHash &&
          other.imageHashes == this.imageHashes &&
          other.isDeleted == this.isDeleted &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class NotesCompanion extends UpdateCompanion<Note> {
  final Value<String> noteId;
  final Value<String> title;
  final Value<String> content;
  final Value<String> excerpt;
  final Value<String> versionVector;
  final Value<String> contentHash;
  final Value<String> imageHashes;
  final Value<bool> isDeleted;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const NotesCompanion({
    this.noteId = const Value.absent(),
    this.title = const Value.absent(),
    this.content = const Value.absent(),
    this.excerpt = const Value.absent(),
    this.versionVector = const Value.absent(),
    this.contentHash = const Value.absent(),
    this.imageHashes = const Value.absent(),
    this.isDeleted = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  NotesCompanion.insert({
    required String noteId,
    required String title,
    required String content,
    required String excerpt,
    required String versionVector,
    required String contentHash,
    required String imageHashes,
    this.isDeleted = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : noteId = Value(noteId),
       title = Value(title),
       content = Value(content),
       excerpt = Value(excerpt),
       versionVector = Value(versionVector),
       contentHash = Value(contentHash),
       imageHashes = Value(imageHashes),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<Note> custom({
    Expression<String>? noteId,
    Expression<String>? title,
    Expression<String>? content,
    Expression<String>? excerpt,
    Expression<String>? versionVector,
    Expression<String>? contentHash,
    Expression<String>? imageHashes,
    Expression<bool>? isDeleted,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (noteId != null) 'note_id': noteId,
      if (title != null) 'title': title,
      if (content != null) 'content': content,
      if (excerpt != null) 'excerpt': excerpt,
      if (versionVector != null) 'version_vector': versionVector,
      if (contentHash != null) 'content_hash': contentHash,
      if (imageHashes != null) 'image_hashes': imageHashes,
      if (isDeleted != null) 'is_deleted': isDeleted,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  NotesCompanion copyWith({
    Value<String>? noteId,
    Value<String>? title,
    Value<String>? content,
    Value<String>? excerpt,
    Value<String>? versionVector,
    Value<String>? contentHash,
    Value<String>? imageHashes,
    Value<bool>? isDeleted,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return NotesCompanion(
      noteId: noteId ?? this.noteId,
      title: title ?? this.title,
      content: content ?? this.content,
      excerpt: excerpt ?? this.excerpt,
      versionVector: versionVector ?? this.versionVector,
      contentHash: contentHash ?? this.contentHash,
      imageHashes: imageHashes ?? this.imageHashes,
      isDeleted: isDeleted ?? this.isDeleted,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (noteId.present) {
      map['note_id'] = Variable<String>(noteId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (excerpt.present) {
      map['excerpt'] = Variable<String>(excerpt.value);
    }
    if (versionVector.present) {
      map['version_vector'] = Variable<String>(versionVector.value);
    }
    if (contentHash.present) {
      map['content_hash'] = Variable<String>(contentHash.value);
    }
    if (imageHashes.present) {
      map['image_hashes'] = Variable<String>(imageHashes.value);
    }
    if (isDeleted.present) {
      map['is_deleted'] = Variable<bool>(isDeleted.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('NotesCompanion(')
          ..write('noteId: $noteId, ')
          ..write('title: $title, ')
          ..write('content: $content, ')
          ..write('excerpt: $excerpt, ')
          ..write('versionVector: $versionVector, ')
          ..write('contentHash: $contentHash, ')
          ..write('imageHashes: $imageHashes, ')
          ..write('isDeleted: $isDeleted, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncBaselinesTable extends SyncBaselines
    with TableInfo<$SyncBaselinesTable, SyncBaseline> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncBaselinesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _noteIdMeta = const VerificationMeta('noteId');
  @override
  late final GeneratedColumn<String> noteId = GeneratedColumn<String>(
    'note_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _peerDeviceIdMeta = const VerificationMeta(
    'peerDeviceId',
  );
  @override
  late final GeneratedColumn<String> peerDeviceId = GeneratedColumn<String>(
    'peer_device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionVectorMeta = const VerificationMeta(
    'versionVector',
  );
  @override
  late final GeneratedColumn<String> versionVector = GeneratedColumn<String>(
    'version_vector',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _baseTextMeta = const VerificationMeta(
    'baseText',
  );
  @override
  late final GeneratedColumn<String> baseText = GeneratedColumn<String>(
    'base_text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    noteId,
    peerDeviceId,
    versionVector,
    baseText,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_baselines';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncBaseline> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('note_id')) {
      context.handle(
        _noteIdMeta,
        noteId.isAcceptableOrUnknown(data['note_id']!, _noteIdMeta),
      );
    } else if (isInserting) {
      context.missing(_noteIdMeta);
    }
    if (data.containsKey('peer_device_id')) {
      context.handle(
        _peerDeviceIdMeta,
        peerDeviceId.isAcceptableOrUnknown(
          data['peer_device_id']!,
          _peerDeviceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_peerDeviceIdMeta);
    }
    if (data.containsKey('version_vector')) {
      context.handle(
        _versionVectorMeta,
        versionVector.isAcceptableOrUnknown(
          data['version_vector']!,
          _versionVectorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_versionVectorMeta);
    }
    if (data.containsKey('base_text')) {
      context.handle(
        _baseTextMeta,
        baseText.isAcceptableOrUnknown(data['base_text']!, _baseTextMeta),
      );
    } else if (isInserting) {
      context.missing(_baseTextMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {noteId, peerDeviceId};
  @override
  SyncBaseline map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncBaseline(
      noteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note_id'],
      )!,
      peerDeviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}peer_device_id'],
      )!,
      versionVector: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}version_vector'],
      )!,
      baseText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_text'],
      )!,
    );
  }

  @override
  $SyncBaselinesTable createAlias(String alias) {
    return $SyncBaselinesTable(attachedDatabase, alias);
  }
}

class SyncBaseline extends DataClass implements Insertable<SyncBaseline> {
  final String noteId;
  final String peerDeviceId;
  final String versionVector;

  /// 上次与对端同步时的正文快照。
  final String baseText;
  const SyncBaseline({
    required this.noteId,
    required this.peerDeviceId,
    required this.versionVector,
    required this.baseText,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['note_id'] = Variable<String>(noteId);
    map['peer_device_id'] = Variable<String>(peerDeviceId);
    map['version_vector'] = Variable<String>(versionVector);
    map['base_text'] = Variable<String>(baseText);
    return map;
  }

  SyncBaselinesCompanion toCompanion(bool nullToAbsent) {
    return SyncBaselinesCompanion(
      noteId: Value(noteId),
      peerDeviceId: Value(peerDeviceId),
      versionVector: Value(versionVector),
      baseText: Value(baseText),
    );
  }

  factory SyncBaseline.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncBaseline(
      noteId: serializer.fromJson<String>(json['noteId']),
      peerDeviceId: serializer.fromJson<String>(json['peerDeviceId']),
      versionVector: serializer.fromJson<String>(json['versionVector']),
      baseText: serializer.fromJson<String>(json['baseText']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'noteId': serializer.toJson<String>(noteId),
      'peerDeviceId': serializer.toJson<String>(peerDeviceId),
      'versionVector': serializer.toJson<String>(versionVector),
      'baseText': serializer.toJson<String>(baseText),
    };
  }

  SyncBaseline copyWith({
    String? noteId,
    String? peerDeviceId,
    String? versionVector,
    String? baseText,
  }) => SyncBaseline(
    noteId: noteId ?? this.noteId,
    peerDeviceId: peerDeviceId ?? this.peerDeviceId,
    versionVector: versionVector ?? this.versionVector,
    baseText: baseText ?? this.baseText,
  );
  SyncBaseline copyWithCompanion(SyncBaselinesCompanion data) {
    return SyncBaseline(
      noteId: data.noteId.present ? data.noteId.value : this.noteId,
      peerDeviceId: data.peerDeviceId.present
          ? data.peerDeviceId.value
          : this.peerDeviceId,
      versionVector: data.versionVector.present
          ? data.versionVector.value
          : this.versionVector,
      baseText: data.baseText.present ? data.baseText.value : this.baseText,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncBaseline(')
          ..write('noteId: $noteId, ')
          ..write('peerDeviceId: $peerDeviceId, ')
          ..write('versionVector: $versionVector, ')
          ..write('baseText: $baseText')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(noteId, peerDeviceId, versionVector, baseText);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncBaseline &&
          other.noteId == this.noteId &&
          other.peerDeviceId == this.peerDeviceId &&
          other.versionVector == this.versionVector &&
          other.baseText == this.baseText);
}

class SyncBaselinesCompanion extends UpdateCompanion<SyncBaseline> {
  final Value<String> noteId;
  final Value<String> peerDeviceId;
  final Value<String> versionVector;
  final Value<String> baseText;
  final Value<int> rowid;
  const SyncBaselinesCompanion({
    this.noteId = const Value.absent(),
    this.peerDeviceId = const Value.absent(),
    this.versionVector = const Value.absent(),
    this.baseText = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncBaselinesCompanion.insert({
    required String noteId,
    required String peerDeviceId,
    required String versionVector,
    required String baseText,
    this.rowid = const Value.absent(),
  }) : noteId = Value(noteId),
       peerDeviceId = Value(peerDeviceId),
       versionVector = Value(versionVector),
       baseText = Value(baseText);
  static Insertable<SyncBaseline> custom({
    Expression<String>? noteId,
    Expression<String>? peerDeviceId,
    Expression<String>? versionVector,
    Expression<String>? baseText,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (noteId != null) 'note_id': noteId,
      if (peerDeviceId != null) 'peer_device_id': peerDeviceId,
      if (versionVector != null) 'version_vector': versionVector,
      if (baseText != null) 'base_text': baseText,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncBaselinesCompanion copyWith({
    Value<String>? noteId,
    Value<String>? peerDeviceId,
    Value<String>? versionVector,
    Value<String>? baseText,
    Value<int>? rowid,
  }) {
    return SyncBaselinesCompanion(
      noteId: noteId ?? this.noteId,
      peerDeviceId: peerDeviceId ?? this.peerDeviceId,
      versionVector: versionVector ?? this.versionVector,
      baseText: baseText ?? this.baseText,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (noteId.present) {
      map['note_id'] = Variable<String>(noteId.value);
    }
    if (peerDeviceId.present) {
      map['peer_device_id'] = Variable<String>(peerDeviceId.value);
    }
    if (versionVector.present) {
      map['version_vector'] = Variable<String>(versionVector.value);
    }
    if (baseText.present) {
      map['base_text'] = Variable<String>(baseText.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncBaselinesCompanion(')
          ..write('noteId: $noteId, ')
          ..write('peerDeviceId: $peerDeviceId, ')
          ..write('versionVector: $versionVector, ')
          ..write('baseText: $baseText, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SearchIndexTable extends SearchIndex
    with TableInfo<$SearchIndexTable, SearchIndexData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SearchIndexTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _noteIdMeta = const VerificationMeta('noteId');
  @override
  late final GeneratedColumn<String> noteId = GeneratedColumn<String>(
    'note_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [noteId, title, content];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'search_index';
  @override
  VerificationContext validateIntegrity(
    Insertable<SearchIndexData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('note_id')) {
      context.handle(
        _noteIdMeta,
        noteId.isAcceptableOrUnknown(data['note_id']!, _noteIdMeta),
      );
    } else if (isInserting) {
      context.missing(_noteIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {noteId};
  @override
  SearchIndexData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SearchIndexData(
      noteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
    );
  }

  @override
  $SearchIndexTable createAlias(String alias) {
    return $SearchIndexTable(attachedDatabase, alias);
  }
}

class SearchIndexData extends DataClass implements Insertable<SearchIndexData> {
  final String noteId;
  final String title;
  final String content;
  const SearchIndexData({
    required this.noteId,
    required this.title,
    required this.content,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['note_id'] = Variable<String>(noteId);
    map['title'] = Variable<String>(title);
    map['content'] = Variable<String>(content);
    return map;
  }

  SearchIndexCompanion toCompanion(bool nullToAbsent) {
    return SearchIndexCompanion(
      noteId: Value(noteId),
      title: Value(title),
      content: Value(content),
    );
  }

  factory SearchIndexData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SearchIndexData(
      noteId: serializer.fromJson<String>(json['noteId']),
      title: serializer.fromJson<String>(json['title']),
      content: serializer.fromJson<String>(json['content']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'noteId': serializer.toJson<String>(noteId),
      'title': serializer.toJson<String>(title),
      'content': serializer.toJson<String>(content),
    };
  }

  SearchIndexData copyWith({String? noteId, String? title, String? content}) =>
      SearchIndexData(
        noteId: noteId ?? this.noteId,
        title: title ?? this.title,
        content: content ?? this.content,
      );
  SearchIndexData copyWithCompanion(SearchIndexCompanion data) {
    return SearchIndexData(
      noteId: data.noteId.present ? data.noteId.value : this.noteId,
      title: data.title.present ? data.title.value : this.title,
      content: data.content.present ? data.content.value : this.content,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SearchIndexData(')
          ..write('noteId: $noteId, ')
          ..write('title: $title, ')
          ..write('content: $content')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(noteId, title, content);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SearchIndexData &&
          other.noteId == this.noteId &&
          other.title == this.title &&
          other.content == this.content);
}

class SearchIndexCompanion extends UpdateCompanion<SearchIndexData> {
  final Value<String> noteId;
  final Value<String> title;
  final Value<String> content;
  final Value<int> rowid;
  const SearchIndexCompanion({
    this.noteId = const Value.absent(),
    this.title = const Value.absent(),
    this.content = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SearchIndexCompanion.insert({
    required String noteId,
    required String title,
    required String content,
    this.rowid = const Value.absent(),
  }) : noteId = Value(noteId),
       title = Value(title),
       content = Value(content);
  static Insertable<SearchIndexData> custom({
    Expression<String>? noteId,
    Expression<String>? title,
    Expression<String>? content,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (noteId != null) 'note_id': noteId,
      if (title != null) 'title': title,
      if (content != null) 'content': content,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SearchIndexCompanion copyWith({
    Value<String>? noteId,
    Value<String>? title,
    Value<String>? content,
    Value<int>? rowid,
  }) {
    return SearchIndexCompanion(
      noteId: noteId ?? this.noteId,
      title: title ?? this.title,
      content: content ?? this.content,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (noteId.present) {
      map['note_id'] = Variable<String>(noteId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SearchIndexCompanion(')
          ..write('noteId: $noteId, ')
          ..write('title: $title, ')
          ..write('content: $content, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $NotesTable notes = $NotesTable(this);
  late final $SyncBaselinesTable syncBaselines = $SyncBaselinesTable(this);
  late final $SearchIndexTable searchIndex = $SearchIndexTable(this);
  late final Index idxNotesUpdated = Index(
    'idx_notes_updated',
    'CREATE INDEX idx_notes_updated ON notes (updated_at)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    notes,
    syncBaselines,
    searchIndex,
    idxNotesUpdated,
  ];
}

typedef $$NotesTableCreateCompanionBuilder = NotesCompanion Function({
  required String noteId,
  required String title,
  required String content,
  required String excerpt,
  required String versionVector,
  required String contentHash,
  required String imageHashes,
  Value<bool> isDeleted,
  required int createdAt,
  required int updatedAt,
  Value<int> rowid,
});
typedef $$NotesTableUpdateCompanionBuilder = NotesCompanion Function({
  Value<String> noteId,
  Value<String> title,
  Value<String> content,
  Value<String> excerpt,
  Value<String> versionVector,
  Value<String> contentHash,
  Value<String> imageHashes,
  Value<bool> isDeleted,
  Value<int> createdAt,
  Value<int> updatedAt,
  Value<int> rowid,
});

class $$NotesTableFilterComposer extends Composer<_$AppDatabase, $NotesTable> {
  $$NotesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get noteId => $composableBuilder(
    column: $table.noteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get excerpt => $composableBuilder(
    column: $table.excerpt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get versionVector => $composableBuilder(
    column: $table.versionVector,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentHash => $composableBuilder(
    column: $table.contentHash,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get imageHashes => $composableBuilder(
    column: $table.imageHashes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDeleted => $composableBuilder(
    column: $table.isDeleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$NotesTableOrderingComposer
    extends Composer<_$AppDatabase, $NotesTable> {
  $$NotesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get noteId => $composableBuilder(
    column: $table.noteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get excerpt => $composableBuilder(
    column: $table.excerpt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get versionVector => $composableBuilder(
    column: $table.versionVector,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentHash => $composableBuilder(
    column: $table.contentHash,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get imageHashes => $composableBuilder(
    column: $table.imageHashes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDeleted => $composableBuilder(
    column: $table.isDeleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$NotesTableAnnotationComposer
    extends Composer<_$AppDatabase, $NotesTable> {
  $$NotesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get noteId =>
      $composableBuilder(column: $table.noteId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<String> get excerpt =>
      $composableBuilder(column: $table.excerpt, builder: (column) => column);

  GeneratedColumn<String> get versionVector => $composableBuilder(
    column: $table.versionVector,
    builder: (column) => column,
  );

  GeneratedColumn<String> get contentHash => $composableBuilder(
    column: $table.contentHash,
    builder: (column) => column,
  );

  GeneratedColumn<String> get imageHashes => $composableBuilder(
    column: $table.imageHashes,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isDeleted =>
      $composableBuilder(column: $table.isDeleted, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$NotesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $NotesTable,
          Note,
          $$NotesTableFilterComposer,
          $$NotesTableOrderingComposer,
          $$NotesTableAnnotationComposer,
          $$NotesTableCreateCompanionBuilder,
          $$NotesTableUpdateCompanionBuilder,
          (Note, BaseReferences<_$AppDatabase, $NotesTable, Note>),
          Note,
          PrefetchHooks Function()
        > {
  $$NotesTableTableManager(_$AppDatabase db, $NotesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$NotesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$NotesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$NotesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> noteId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<String> excerpt = const Value.absent(),
                Value<String> versionVector = const Value.absent(),
                Value<String> contentHash = const Value.absent(),
                Value<String> imageHashes = const Value.absent(),
                Value<bool> isDeleted = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotesCompanion(
                noteId: noteId,
                title: title,
                content: content,
                excerpt: excerpt,
                versionVector: versionVector,
                contentHash: contentHash,
                imageHashes: imageHashes,
                isDeleted: isDeleted,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String noteId,
                required String title,
                required String content,
                required String excerpt,
                required String versionVector,
                required String contentHash,
                required String imageHashes,
                Value<bool> isDeleted = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => NotesCompanion.insert(
                noteId: noteId,
                title: title,
                content: content,
                excerpt: excerpt,
                versionVector: versionVector,
                contentHash: contentHash,
                imageHashes: imageHashes,
                isDeleted: isDeleted,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$NotesTable, Note>(table),
                  BaseReferences<_$AppDatabase, $NotesTable, Note>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$NotesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $NotesTable,
      Note,
      $$NotesTableFilterComposer,
      $$NotesTableOrderingComposer,
      $$NotesTableAnnotationComposer,
      $$NotesTableCreateCompanionBuilder,
      $$NotesTableUpdateCompanionBuilder,
      (Note, BaseReferences<_$AppDatabase, $NotesTable, Note>),
      Note,
      PrefetchHooks Function()
    >;
typedef $$SyncBaselinesTableCreateCompanionBuilder =
    SyncBaselinesCompanion Function({
      required String noteId,
      required String peerDeviceId,
      required String versionVector,
      required String baseText,
      Value<int> rowid,
    });
typedef $$SyncBaselinesTableUpdateCompanionBuilder =
    SyncBaselinesCompanion Function({
      Value<String> noteId,
      Value<String> peerDeviceId,
      Value<String> versionVector,
      Value<String> baseText,
      Value<int> rowid,
    });

class $$SyncBaselinesTableFilterComposer
    extends Composer<_$AppDatabase, $SyncBaselinesTable> {
  $$SyncBaselinesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get noteId => $composableBuilder(
    column: $table.noteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get peerDeviceId => $composableBuilder(
    column: $table.peerDeviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get versionVector => $composableBuilder(
    column: $table.versionVector,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseText => $composableBuilder(
    column: $table.baseText,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncBaselinesTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncBaselinesTable> {
  $$SyncBaselinesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get noteId => $composableBuilder(
    column: $table.noteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get peerDeviceId => $composableBuilder(
    column: $table.peerDeviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get versionVector => $composableBuilder(
    column: $table.versionVector,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseText => $composableBuilder(
    column: $table.baseText,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncBaselinesTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncBaselinesTable> {
  $$SyncBaselinesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get noteId =>
      $composableBuilder(column: $table.noteId, builder: (column) => column);

  GeneratedColumn<String> get peerDeviceId => $composableBuilder(
    column: $table.peerDeviceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get versionVector => $composableBuilder(
    column: $table.versionVector,
    builder: (column) => column,
  );

  GeneratedColumn<String> get baseText =>
      $composableBuilder(column: $table.baseText, builder: (column) => column);
}

class $$SyncBaselinesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncBaselinesTable,
          SyncBaseline,
          $$SyncBaselinesTableFilterComposer,
          $$SyncBaselinesTableOrderingComposer,
          $$SyncBaselinesTableAnnotationComposer,
          $$SyncBaselinesTableCreateCompanionBuilder,
          $$SyncBaselinesTableUpdateCompanionBuilder,
          (
            SyncBaseline,
            BaseReferences<_$AppDatabase, $SyncBaselinesTable, SyncBaseline>,
          ),
          SyncBaseline,
          PrefetchHooks Function()
        > {
  $$SyncBaselinesTableTableManager(_$AppDatabase db, $SyncBaselinesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncBaselinesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncBaselinesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncBaselinesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> noteId = const Value.absent(),
                Value<String> peerDeviceId = const Value.absent(),
                Value<String> versionVector = const Value.absent(),
                Value<String> baseText = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncBaselinesCompanion(
                noteId: noteId,
                peerDeviceId: peerDeviceId,
                versionVector: versionVector,
                baseText: baseText,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String noteId,
                required String peerDeviceId,
                required String versionVector,
                required String baseText,
                Value<int> rowid = const Value.absent(),
              }) => SyncBaselinesCompanion.insert(
                noteId: noteId,
                peerDeviceId: peerDeviceId,
                versionVector: versionVector,
                baseText: baseText,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncBaselinesTable, SyncBaseline>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $SyncBaselinesTable,
                    SyncBaseline
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncBaselinesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncBaselinesTable,
      SyncBaseline,
      $$SyncBaselinesTableFilterComposer,
      $$SyncBaselinesTableOrderingComposer,
      $$SyncBaselinesTableAnnotationComposer,
      $$SyncBaselinesTableCreateCompanionBuilder,
      $$SyncBaselinesTableUpdateCompanionBuilder,
      (
        SyncBaseline,
        BaseReferences<_$AppDatabase, $SyncBaselinesTable, SyncBaseline>,
      ),
      SyncBaseline,
      PrefetchHooks Function()
    >;
typedef $$SearchIndexTableCreateCompanionBuilder =
    SearchIndexCompanion Function({
      required String noteId,
      required String title,
      required String content,
      Value<int> rowid,
    });
typedef $$SearchIndexTableUpdateCompanionBuilder =
    SearchIndexCompanion Function({
      Value<String> noteId,
      Value<String> title,
      Value<String> content,
      Value<int> rowid,
    });

class $$SearchIndexTableFilterComposer
    extends Composer<_$AppDatabase, $SearchIndexTable> {
  $$SearchIndexTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get noteId => $composableBuilder(
    column: $table.noteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SearchIndexTableOrderingComposer
    extends Composer<_$AppDatabase, $SearchIndexTable> {
  $$SearchIndexTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get noteId => $composableBuilder(
    column: $table.noteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SearchIndexTableAnnotationComposer
    extends Composer<_$AppDatabase, $SearchIndexTable> {
  $$SearchIndexTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get noteId =>
      $composableBuilder(column: $table.noteId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);
}

class $$SearchIndexTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SearchIndexTable,
          SearchIndexData,
          $$SearchIndexTableFilterComposer,
          $$SearchIndexTableOrderingComposer,
          $$SearchIndexTableAnnotationComposer,
          $$SearchIndexTableCreateCompanionBuilder,
          $$SearchIndexTableUpdateCompanionBuilder,
          (
            SearchIndexData,
            BaseReferences<_$AppDatabase, $SearchIndexTable, SearchIndexData>,
          ),
          SearchIndexData,
          PrefetchHooks Function()
        > {
  $$SearchIndexTableTableManager(_$AppDatabase db, $SearchIndexTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SearchIndexTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SearchIndexTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SearchIndexTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> noteId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SearchIndexCompanion(
                noteId: noteId,
                title: title,
                content: content,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String noteId,
                required String title,
                required String content,
                Value<int> rowid = const Value.absent(),
              }) => SearchIndexCompanion.insert(
                noteId: noteId,
                title: title,
                content: content,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SearchIndexTable, SearchIndexData>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $SearchIndexTable,
                    SearchIndexData
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SearchIndexTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SearchIndexTable,
      SearchIndexData,
      $$SearchIndexTableFilterComposer,
      $$SearchIndexTableOrderingComposer,
      $$SearchIndexTableAnnotationComposer,
      $$SearchIndexTableCreateCompanionBuilder,
      $$SearchIndexTableUpdateCompanionBuilder,
      (
        SearchIndexData,
        BaseReferences<_$AppDatabase, $SearchIndexTable, SearchIndexData>,
      ),
      SearchIndexData,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$NotesTableTableManager get notes =>
      $$NotesTableTableManager(_db, _db.notes);
  $$SyncBaselinesTableTableManager get syncBaselines =>
      $$SyncBaselinesTableTableManager(_db, _db.syncBaselines);
  $$SearchIndexTableTableManager get searchIndex =>
      $$SearchIndexTableTableManager(_db, _db.searchIndex);
}
