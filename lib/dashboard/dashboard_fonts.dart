/// The fonts a dashboard widget can be set in.
///
/// All bundled with the app rather than fetched at runtime: the panel is
/// often the only thing awake in the house and may have no working network
/// when it starts, and a dashboard that falls back to a different typeface
/// when the internet is down is worse than one that never offers the choice.
///
/// Every one is under the SIL Open Font License, which permits bundling and
/// redistribution. The licence text ships beside each file in `assets/fonts/`.
library;

/// Loose grouping, shown as headings in the editor's font list so twenty
/// choices read as a few short lists rather than one long one.
enum FontGroup { plain, friendly, tech, display }

String fontGroupLabel(FontGroup g) {
  switch (g) {
    case FontGroup.plain:
      return 'Plain';
    case FontGroup.friendly:
      return 'Friendly';
    case FontGroup.tech:
      return 'Technical';
    case FontGroup.display:
      return 'Display';
  }
}

class DashboardFont {
  /// Family name as declared in `pubspec.yaml`, and what gets stored in the
  /// config. The empty string means "whatever the theme says".
  final String family;
  final String name;
  final String description;

  /// The bundled file, served to the browser editor so its preview uses the
  /// same typeface the panel will.
  final String file;

  final FontGroup group;

  const DashboardFont({
    required this.family,
    required this.name,
    required this.description,
    required this.file,
    this.group = FontGroup.plain,
  });

  Map<String, dynamic> toJson() => {
        'family': family,
        'name': name,
        'description': description,
        'file': file,
        'group': group.name,
        'groupLabel': fontGroupLabel(group),
      };
}

const List<DashboardFont> kDashboardFonts = [
  DashboardFont(
    family: '',
    name: 'Theme default',
    description: 'Whatever the theme specifies, or the app’s own font.',
    file: '',
  ),
  DashboardFont(
    family: 'Inter',
    name: 'Inter',
    description: 'Neutral and very legible at a distance. A safe default.',
    file: 'Inter.ttf',
  ),
  DashboardFont(
    family: 'SourceSans3',
    name: 'Source Sans 3',
    description: 'Warmer than Inter, still plain. Good for text-heavy tiles.',
    file: 'SourceSans3.ttf',
  ),
  DashboardFont(
    family: 'Lora',
    name: 'Lora',
    description: 'A serif. Suits a calendar or headlines more than a clock.',
    file: 'Lora.ttf',
  ),
  DashboardFont(
    family: 'JetBrainsMono',
    name: 'JetBrains Mono',
    description:
        'Fixed width, so a clock’s digits do not shuffle as they change.',
    file: 'JetBrainsMono.ttf',
  ),
  DashboardFont(
    family: 'Oswald',
    name: 'Oswald',
    description: 'Tall and condensed. Fits a big clock into a small tile.',
    file: 'Oswald.ttf',
    group: FontGroup.display,
  ),

  // Friendly — rounded and soft. Good on a kitchen wall, less so on a
  // dashboard you are trying to read numbers off in a hurry.
  DashboardFont(
    family: 'Quicksand',
    name: 'Quicksand',
    description: 'Rounded and light. Cheerful without being childish.',
    file: 'Quicksand.ttf',
    group: FontGroup.friendly,
  ),
  DashboardFont(
    family: 'Comfortaa',
    name: 'Comfortaa',
    description: 'Very round, quite wide. Best on tiles with few words.',
    file: 'Comfortaa.ttf',
    group: FontGroup.friendly,
  ),
  DashboardFont(
    family: 'Nunito',
    name: 'Nunito',
    description: 'Softened corners on an otherwise ordinary sans. Easy going.',
    file: 'Nunito.ttf',
    group: FontGroup.friendly,
  ),
  DashboardFont(
    family: 'Fredoka',
    name: 'Fredoka',
    description: 'Chunky and bubbly. Reads as playful at any size.',
    file: 'Fredoka.ttf',
    group: FontGroup.friendly,
  ),
  DashboardFont(
    family: 'ComicNeue',
    name: 'Comic Neue',
    description: 'The famous one, redrawn to be tolerable. Handwritten feel.',
    file: 'ComicNeue.ttf',
    group: FontGroup.friendly,
  ),
  DashboardFont(
    family: 'PatrickHand',
    name: 'Patrick Hand',
    description: 'Actual handwriting. Suits a calendar or a note.',
    file: 'PatrickHand.ttf',
    group: FontGroup.friendly,
  ),

  // Technical — squared, mechanical, or straight out of a terminal.
  DashboardFont(
    family: 'Orbitron',
    name: 'Orbitron',
    description: 'Square and geometric. The one that looks like a spaceship.',
    file: 'Orbitron.ttf',
    group: FontGroup.tech,
  ),
  DashboardFont(
    family: 'ChakraPetch',
    name: 'Chakra Petch',
    description: 'Angular and slightly condensed. Technical without shouting.',
    file: 'ChakraPetch.ttf',
    group: FontGroup.tech,
  ),
  DashboardFont(
    family: 'ShareTechMono',
    name: 'Share Tech Mono',
    description: 'Fixed width with a machine-readout look.',
    file: 'ShareTechMono.ttf',
    group: FontGroup.tech,
  ),
  DashboardFont(
    family: 'SpaceMono',
    name: 'Space Mono',
    description: 'Fixed width with odd, characterful letterforms.',
    file: 'SpaceMono.ttf',
    group: FontGroup.tech,
  ),
  DashboardFont(
    family: 'VT323',
    name: 'VT323',
    description: 'A 1970s serial terminal. Wants to be large and green.',
    file: 'VT323.ttf',
    group: FontGroup.tech,
  ),
  DashboardFont(
    family: 'PressStart2P',
    name: 'Press Start 2P',
    description:
        'Arcade pixels. Very wide per character — give it a big tile and '
        'few words, or a clock with no seconds.',
    file: 'PressStart2P.ttf',
    group: FontGroup.tech,
  ),

  // Display — for one big thing, not for paragraphs.
  DashboardFont(
    family: 'BebasNeue',
    name: 'Bebas Neue',
    description: 'Tall condensed capitals. Enormous numbers in a small space.',
    file: 'BebasNeue.ttf',
    group: FontGroup.display,
  ),
  DashboardFont(
    family: 'Bangers',
    name: 'Bangers',
    description: 'Comic book lettering. Loud, and knows it.',
    file: 'Bangers.ttf',
    group: FontGroup.display,
  ),
];

/// Sizes offered per widget, as a multiplier on whatever the widget draws at
/// its own scale.
///
/// A multiplier rather than a point size because widgets size themselves from
/// their tile — a clock in a two-cell tile and the same clock across half the
/// panel are already very different sizes, and a fixed point size would fight
/// that rather than adjust it.
const Map<String, double> kFontScales = {
  'Tiny': 0.6,
  'Very small': 0.7,
  'Smaller': 0.8,
  'Small': 0.9,
  'Normal': 1.0,
  'Slightly larger': 1.1,
  'Large': 1.25,
  'Larger': 1.4,
  'Very large': 1.6,
  'Huge': 1.8,
  'Enormous': 2.0,
  'Absurd': 2.5,
};
