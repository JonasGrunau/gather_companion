/// What the office *looks* like, as opposed to what it blocks.
///
/// [SpaceMap] answers "can a body stand here". This answers "what is drawn here",
/// from the same rows of the same state dump — `MapArea` carries a floor and a wall
/// texture, `CatalogItemVariant` carries a sprite. Neither is served over REST any
/// more than the geometry is.
///
/// ## Gather does not ship a tileset
///
/// There is no per-space art bundle to download. The client resolves three kinds of
/// image and fetches each one on its own, then packs them into a texture atlas in a
/// worker at runtime:
///
///  - **Floors** — one 32×32 PNG per area, tiled across it, on `app.v2.gather.town`
///    under `/images/studio/new-assets/walls-and-floors/floors/`.
///  - **Walls** — 32×64 pieces for the north and south bands, 32×32 for the sides,
///    one folder per wall style under `…/walls/<Style>/`.
///  - **Furniture** — one PNG per `CatalogItemVariant`, named by the variant's own
///    `mainRenderable.imageUrl`, on `static.gather.town`.
///
/// All three are public: fetched here with no credentials and no cookies, they
/// answer 200. On the measured space that is 477 furniture sprites, five floor tiles
/// and eight wall pieces — about 200 KB in total, because each sprite is a few
/// hundred bytes. So "download the whole tileset" is a real option on a phone, and
/// this file is the list of what to ask for and where to put it.
///
/// ## Transcribed, not invented
///
/// Same rule as `space_map.dart`: every formula below is read out of the client
/// bundle (`app.v2.gather.town`, chunk `bundle.c2029c930c009964.js`) rather than
/// guessed from how the result looks. Where a comment names something like
/// `updateDepth` or `ensureImmersiveWalls`, that is the real identifier.
///
/// **The floor filename is composed from two fields.** `MapArea` carries
/// `floorTexture` (a `GroundTextureKeyV2`) and `floorColor` (a `FloorColor`), and the
/// client's `d(texture, colour, isDark)` joins them:
///
/// ```js
/// function d(A,e,g){                        // texture, colour, isDark
///   const t=o[A]; if(!t) return undefined;  // base name, e.g. WoodSlats -> Wood_Slats
///   const I=r[A]; if(I&&!I.includes(e)) return undefined;   // NewStyleGrass: Green only
///   const i=E[e];                           // colour name — the enum value verbatim
///   const B=g?"_Dark":"";
///   return `${t}_${i}${B}.png`;
/// }
/// ```
///
/// When that returns nothing the client falls back to a flat per-theme table keyed by
/// texture alone. Both tables are below, copied out of the bundle rather than retyped.
///
/// **Walls are bands, not outlines.** `ensureImmersiveWalls` builds four edges from
/// the wall style's folder: a north band two tiles tall sitting *above* the area's top
/// row, a south band two tiles tall covering its bottom two rows, and single-tile
/// columns down the sides between them. Corners belong to the north and south bands,
/// which is why the sides run from row 0 to row `height - 3`. Doorway tiles are left
/// out, which is what makes a door a hole rather than a picture.
///
/// **The ground has three layers, and they are not sorted by position.** This is the
/// one that looked like a bug when it was got wrong: drawn in bottom-edge order the
/// base area, being the tallest thing on the map, paints over every room inside it.
/// `getBaseDepthForSimplifiedAreaFloor` is the real rule, and it is a lookup, not a
/// coordinate:
///
/// ```js
/// if (A.isBaseArea) return YZ.BaseAreaGround;              // 0
/// if (A.mapAreaType === MapAreaType.Public) return YZ.PublicAreaGround;  // 2
/// return YZ.AreaGround;                                    // 4
/// ```
///
/// Position only breaks ties inside a layer: `updateFloorsDepth` adds
/// `AD(bottomEdge)/9999 + nesting/1000` to that constant, and both terms are under
/// a thousandth of the gap between layers.
///
/// **A wall has one of two depths, and which one depends on whether it is
/// horizontal.** The side walls take their area's floor depth — the area is one
/// Phaser container — which puts them under every piece of furniture, so a plant
/// standing against one covers it and occlusion the other way is what
/// `foregroundRenderable` is for. The north and south bands are given depths of their
/// own, and `ensureImmersiveWalls` is explicit about it:
///
/// ```js
/// const north = QS(this.container.y + .1);
/// const south = QS(this.container.y + area.height * TILE_SIZE);
/// this.northEdge.ensure(…, north, …); this.northEdge.setPosition(0, -nw);
/// this.southEdge.ensure(…, south, …); this.southEdge.setPosition(0, area.height*32 - nw);
/// ```
///
/// So the north band sorts at its area's top line — it hangs entirely above the
/// floor, and covers only what stands north of the room — while the south band sorts
/// at the *bottom* line while hanging over the room's last two rows, which is what
/// puts it in front of the desks and the people down there. Given the sides' depth
/// instead it ends up behind them, which is what it looked like. That is why the
/// bands are [ArtSprite]s in [SpaceArt.props] and only the sides are [ArtWall]s in
/// [SpaceArt.ground].
///
/// **Depth is the fold, not the row.** `updateDepth` sorts a sprite by
/// `topLeftAbsolutePosition.y * TILE_SIZE + renderable.fold` — `fold` being the pixel
/// line inside the sprite where it meets the floor, 0…137 on the measured space. A
/// tall bookcase and the rug in front of it can share a tile and still stack
/// correctly. Anything nested inside another object sorts with its parent, so a lamp
/// on a desk travels with the desk instead of sinking through it.
library;

/// Pixels per tile. `TILE_SIZE` in the bundle.
const artTileSize = 32;

/// Where the client's own static art lives. Not a CDN of ours: these are the exact
/// paths `app.v2.gather.town` serves to the desktop client, and they are public.
const _artHost = 'https://app.v2.gather.town';
const _floorsFolder = '/images/studio/new-assets/walls-and-floors/floors/';
const _wallsFolder = '/images/studio/new-assets/walls-and-floors/walls/';

/// Furniture art. A variant's `imageUrl` is a path on this host unless it already
/// carries a scheme — `constructCatalogAssetUrl` in the bundle.
const _catalogHost = 'https://static.gather.town';

/// Which piece of a wall an edge tile gets. The filenames carry spaces, which is why
/// every URL here goes through [Uri.encodeComponent].
enum WallPiece {
  northWest('thin wall nw.png'),
  north('thin wall n.png'),
  northEast('thin wall ne.png'),
  west('thin wall w.png'),
  east('thin wall e.png'),
  southWest('thin wall sw.png'),
  south('thin wall s.png'),
  southEast('thin wall se.png');

  const WallPiece(this.file);

  final String file;
}

/// The ground: an area's floor, or one tile of the walls around it.
///
/// One list rather than two because they share a depth band — an area is a single
/// container in the client and its walls carry its floor's depth — and because the
/// order between them is fixed anyway: a room's walls sit on its own floor.
sealed class ArtGround {
  const ArtGround({
    required this.url,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final String url;

  /// Map pixels — tiles × 32, with the origin at the grid's top left.
  final double left;
  final double top;
  final double width;
  final double height;
}

/// One area's floor: a 32×32 tile repeated across the rectangle.
class ArtFloor extends ArtGround {
  const ArtFloor({
    required super.url,
    required super.left,
    required super.top,
    required super.width,
    required super.height,
  });
}

/// One wall tile. 32×64 along the north and south bands, 32×32 down the sides.
class ArtWall extends ArtGround {
  const ArtWall({
    required super.url,
    required super.left,
    required super.top,
    required super.width,
    required super.height,
  });
}

/// Anything that sorts by depth against the people: a piece of furniture, the part of
/// one that draws over them, or a horizontal wall band.
class ArtSprite {
  const ArtSprite({
    required this.url,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.depth,
    this.foreground = false,
  });

  final String url;
  final double left;
  final double top;

  /// The variant's `dimensionsInPixels`. Matches the PNG's own size on every sample
  /// checked, so it is a placeholder box while the image is still in flight rather
  /// than a scale to force the image into.
  final double width;
  final double height;

  /// `topLeftAbsolutePosition.y * 32 + renderable.fold` for furniture; for a wall
  /// band, its area's own top or bottom line — see the library doc.
  final double depth;

  /// A `foregroundRenderable`: the half of an object that belongs *in front of*
  /// whoever is standing behind it — the near side of a booth, the back of a screen.
  /// 61 of 477 variants have one, and they are the client's whole mechanism for
  /// letting a body stand behind something.
  final bool foreground;
}

/// Everything drawable on one floor, in the order it is drawn.
class SpaceArt {
  const SpaceArt({
    required this.width,
    required this.height,
    required this.ground,
    required this.props,
    this.awaiting = 0,
  });

  /// The grid, in map pixels.
  final double width;
  final double height;

  /// Floors and side walls, already in paint order: base area, then `Public` areas,
  /// then everything else, and within a layer by nesting and then by bottom edge. Not
  /// sortable by any single number, which is why it arrives sorted.
  final List<ArtGround> ground;

  /// Furniture and the horizontal wall bands, sorted by [ArtSprite.depth]. People
  /// belong in this same order by their own feet; [ArtSprite.foreground] pieces go
  /// over all of it.
  final List<ArtSprite> props;

  /// Furniture on this floor that cannot be drawn yet, because the
  /// `CatalogItemVariant` naming its picture has not arrived.
  ///
  /// Non-zero for the first seconds of every connection, and sometimes for a good
  /// deal longer. The dump is four `FullStateChunk`s and ~5400 patches, and the 93
  /// `MapArea` rows that make a floor drawable are two orders of magnitude cheaper
  /// to send than the 477 `CatalogItemVariant` rows that say what the 1140
  /// `MapObject`s look like — so the office becomes drawable, in full colour, with
  /// none of its furniture in it. There is nothing to draw in its place either: an
  /// object's collision tiles come off the same variant, so the schematic that used
  /// to stand in for missing artwork is empty for exactly as long as this is not.
  ///
  /// Which makes this the difference between an office that is still arriving and
  /// an office with no desks in it, and the screen has no other way to tell.
  final int awaiting;

  /// Every distinct image this floor needs, which is exactly what to prefetch.
  Set<String> get urls => {
        for (final item in ground) item.url,
        for (final prop in props) prop.url,
      };

  bool get isEmpty => ground.isEmpty && props.isEmpty;
}

// ---- the client's URL rules, transcribed ---------------------------------------

/// `${floorsFolder}${d(texture, colour, dark) ?? plainTable[texture]}`.
///
/// Null when the texture is one this build of the client has no art for at all —
/// better a bare rectangle than a 404 per tile.
String? floorImageUrl(String? texture, String? colour, {required bool dark}) {
  if (texture == null) return null;

  final base = _colouredFloor[texture];
  final allowed = _colourRestricted[texture];
  if (base != null && colour != null && (allowed == null || allowed.contains(colour))) {
    return '$_artHost$_floorsFolder${base}_$colour${dark ? '_Dark' : ''}.png';
  }

  final plain = (dark ? _plainFloorDark : _plainFloorLight)[texture];
  return plain == null ? null : '$_artHost$_floorsFolder$plain';
}

/// `${wallsFolder}${style}/${piece}` — `innerWallsFolder` in the bundle.
///
/// Null for `NewStyleNoWall`, which is not a style but the absence of one: the area
/// is a grouping rather than a room.
String? wallImageUrl(String? style, WallPiece piece, {required bool dark}) {
  if (style == null) return null;
  final folder = (dark ? _wallStyleDark : _wallStyleLight)[style];
  if (folder == null) return null;
  return '$_artHost$_wallsFolder$folder/${Uri.encodeComponent(piece.file)}';
}

/// `constructCatalogAssetUrl` — absolute URLs pass through, paths get the host.
///
/// The `?t=` the client appends is `catalogItem.lastSyncAuthoredAt`, a cache-buster
/// for its own CDN. It is passed through when known and omitted otherwise; the asset
/// serves either way, which was checked rather than assumed.
String? catalogImageUrl(String? imageUrl, {String? authoredAt}) {
  if (imageUrl == null || imageUrl.isEmpty) return null;
  if (imageUrl.startsWith('http')) return imageUrl;
  final url = '$_catalogHost$imageUrl';
  return authoredAt == null ? url : '$url?t=$authoredAt';
}

// ---- the tables, copied out of the bundle ---------------------------------------

/// `GroundTextureKeyV2` → the stem of a colourable floor tile. The colour and the
/// `_Dark` suffix are appended; see [floorImageUrl].
const _colouredFloor = <String, String>{
  'CarpetAfghani': 'Carpet_Afghani',
  'CarpetCouture': 'Carpet_Couture',
  'CarpetCurls': 'Carpet_Curls',
  'CarpetCurlsTeal': 'Carpet_Curls',
  'CarpetDiamond': 'Carpet_Diamond',
  'CarpetFloral': 'Carpet_Floral',
  'CarpetFloralPurple': 'Carpet_Floral',
  'CarpetStripe': 'Carpet_Stripe',
  'CarpetStripeGray': 'Carpet_Stripe',
  'CarpetWave': 'Carpet_Wavy',
  'CarpetWaveGray': 'Carpet_Wavy',
  'Damask': 'Carpet_Damask',
  'StoneBrick': 'Stone_Brick',
  'StoneTile': 'Tile_Simple',
  'TileHex': 'Tile_Hex',
  'TileTwotone': 'Tile_2tone',
  'TileTwotoneOrange': 'Tile_2tone',
  'WoodBasketweave': 'Wood_Basket',
  'WoodHerringbone': 'Wood_Herringbone',
  'WoodHerringboneLt': 'Wood_Herringbone',
  'WoodParquet': 'Wood_Parquet',
  'WoodSlats': 'Wood_Slats',
  'WoodSlatsLt': 'Wood_Slats',
  'WoodSpiral': 'Wood_Spiral',
  'NewStyleGrass': 'NewStyle_Grass',
};

/// `r` in the bundle: the one texture that exists in a single colour. Everything
/// else takes any `FloorColor`.
const _colourRestricted = <String, Set<String>>{
  'NewStyleGrass': {'Green'},
};

/// The fallback table, light theme — texture alone, no colour.
const _plainFloorLight = <String, String>{
  'NewStyleSquares': 'floor_main_squares.png',
  'NewStyleTrianglesRugDark': 'floor_main_triangles_rug_dark.png',
  'NewStyleTrianglesRug': 'floor_main_triangles_rug.png',
  'NewStylePlanks': 'floor_main_planks.png',
  'NewStyleWaterBordered': 'floor_main_water.png',
  'NewStyleGrassBordered': 'floor_main_grass.png',
  'NewStyleGrass': 'floor_main_grass.png',
  'NewStylePlain': 'floor_main_plain.png',
  'Wood': 'floor_main_grass.png',
  'Grass': 'floor_main_grass.png',
  'RugBlue': 'floor_main_grass.png',
  'Snow': 'floor_main_grass.png',
  'CarpetAfghani': 'Carpet_Afghani.png',
  'CarpetCouture': 'Carpet_Couture.png',
  'CarpetCurls': 'Carpet_Curls.png',
  'CarpetCurlsTeal': 'Carpet_Curls_Teal.png',
  'CarpetDiamond': 'Carpet_Diamond.png',
  'CarpetFloral': 'Carpet_Floral.png',
  'CarpetFloralPurple': 'Carpet_Floral_Purple.png',
  'CarpetStripe': 'Carpet_Stripe.png',
  'CarpetStripeGray': 'Carpet_Stripe_Gray.png',
  'CarpetTexture': 'Carpet_Texture.png',
  'CarpetWave': 'Carpet_Wave.png',
  'CarpetWaveGray': 'Carpet_Wave_Gray.png',
  'Damask': 'Damask.png',
  'StoneBrick': 'Stone_Brick.png',
  'StoneTile': 'Stone_Tile.png',
  'TileHex': 'Tile_Hex.png',
  'TileTwotone': 'Tile_Twotone.png',
  'TileTwotoneOrange': 'Tile_Twotone_Orange.png',
  'WoodBasketweave': 'Wood_Basketweave.png',
  'WoodHerringbone': 'Wood_Herringbone.png',
  'WoodHerringboneLt': 'Wood_Herringbone_Lt.png',
  'WoodParquet': 'Wood_Parquet.png',
  'WoodSlats': 'Wood_Slats.png',
  'WoodSlatsLt': 'Wood_Slats_Lt.png',
  'WoodSpiral': 'Wood_Spiral.png',
};

/// The fallback table, dark theme. Note the wood floors are a different, later set
/// of files (`Redux_…_v2`) — which is why this is a copy and not the light table
/// with a suffix.
const _plainFloorDark = <String, String>{
  'NewStyleSquares': 'Tile_Twotone_Dark.png',
  'NewStyleTrianglesRugDark': 'Carpet_Diamond_Dark.png',
  'NewStyleTrianglesRug': 'Carpet_Diamond_Dark.png',
  'NewStylePlanks': 'Wood_Slats_Dark.png',
  'NewStyleWaterBordered': 'floor_main_water_Dark.png',
  'NewStyleGrassBordered': 'floor_main_grass_Dark.png',
  'NewStyleGrass': 'floor_main_grass_Dark.png',
  'NewStylePlain': 'Carpet_Wave_Gray_Dark.png',
  'Wood': 'floor_main_grass_Dark.png',
  'Grass': 'floor_main_grass_Dark.png',
  'RugBlue': 'floor_main_grass_Dark.png',
  'Snow': 'floor_main_grass_Dark.png',
  'CarpetAfghani': 'Carpet_Afghani_Dark.png',
  'CarpetCouture': 'Carpet_Couture_Dark.png',
  'CarpetCurls': 'Carpet_Curls_Dark.png',
  'CarpetCurlsTeal': 'Carpet_Curls_Teal_Dark.png',
  'CarpetDiamond': 'Carpet_Diamond_Dark.png',
  'CarpetFloral': 'Carpet_Floral_Dark.png',
  'CarpetFloralPurple': 'Carpet_Floral_Purple_Dark.png',
  'CarpetStripe': 'Carpet_Stripe_Dark.png',
  'CarpetStripeGray': 'Carpet_Stripe_Gray_Dark.png',
  'CarpetTexture': 'Carpet_Wave_Dark.png',
  'CarpetWave': 'Carpet_Wave_Dark.png',
  'CarpetWaveGray': 'Carpet_Wave_Gray_Dark.png',
  'Damask': 'Damask_Dark.png',
  'StoneBrick': 'Stone_Brick_Dark.png',
  'StoneTile': 'Stone_Tile_Dark.png',
  'TileHex': 'Tile_Hex_Dark.png',
  'TileTwotone': 'Tile_Twotone_Dark.png',
  'TileTwotoneOrange': 'Tile_Twotone_Orange_Dark.png',
  'WoodBasketweave': 'Redux_Wood_Basketweave_Dark_v2.png',
  'WoodHerringbone': 'Redux_Wood_Herringbone_Dark_v2.png',
  'WoodHerringboneLt': 'Redux_Wood_Herringbone_Lt_Dark.png',
  'WoodParquet': 'Redux_Wood_Parquet_Dark_v2.png',
  'WoodSlats': 'Redux_Wood_Slats_Dark_v2.png',
  'WoodSlatsLt': 'Redux_Wood_Slats_Lt_Dark.png',
  'WoodSpiral': 'Redux_Wood_Spiral_Dark_v2.png',
};

/// `WallTextureKeyV2` → folder, light theme.
const _wallStyleLight = <String, String>{
  'NewStyleClean': 'Clean',
  'PlainBlack': 'Plain_Black',
  'PlainBrown': 'Plain_Brown',
  'PlainGreen': 'Plain_Green',
  'PlainGray': 'Plain_Grey',
  'PlainIndigo': 'Plain_Indigo',
  'PlainOrange': 'Plain_Orange',
  'PlainPink': 'Plain_Pink',
  'PlainPurple': 'Plain_Purple',
  'PlainRed': 'Plain_Red',
  'PlainTan': 'Plain_Tan',
  'PlainTeal': 'Plain_Teal',
  'PlainWhite': 'Plain_White',
  'PlainYellow': 'Plain_Yellow',
};

/// The same, dark theme. `NewStyleClean` has no dark art of its own and borrows
/// `Plain_Teal_Dark`; that is the client's own mapping, not a substitution here.
const _wallStyleDark = <String, String>{
  'NewStyleClean': 'Plain_Teal_Dark',
  'PlainBlack': 'Plain_Black_Dark',
  'PlainBrown': 'Plain_Brown_Dark',
  'PlainGreen': 'Plain_Green_Dark',
  'PlainGray': 'Plain_Grey_Dark',
  'PlainIndigo': 'Plain_Indigo_Dark',
  'PlainOrange': 'Plain_Orange_Dark',
  'PlainPink': 'Plain_Pink_Dark',
  'PlainPurple': 'Plain_Purple_Dark',
  'PlainRed': 'Plain_Red_Dark',
  'PlainTan': 'Plain_Tan_Dark',
  'PlainTeal': 'Plain_Teal_Dark',
  'PlainWhite': 'Plain_White_Dark',
  'PlainYellow': 'Plain_Yellow_Dark',
};
