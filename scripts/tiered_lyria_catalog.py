"""Build the deterministic five-tier Rise & Grind music catalog."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class TierProfile:
    """Describe one alarm-music intensity tier."""

    identifier: str
    display_name: str
    bpm_range: str
    energy_direction: str
    genres: tuple[tuple[str, str], ...]


TIER_PROFILES = (
    TierProfile(
        "soothing",
        "Soothing",
        "58–82 BPM",
        "tender, spacious, reassuring, and gentle enough for the first wake cue",
        (
            ("Ambient", "weightless ambient pads, soft bells, warm sub-bass"),
            ("Neo-Classical", "felt piano, quiet strings, intimate chamber dynamics"),
            ("Dream Pop", "hushed dream-pop guitars and gauzy synthesizers"),
            ("Bossa Nova", "nylon guitar, brushed percussion, understated bossa pulse"),
            ("Soft Jazz", "muted horn, upright bass, brushes, late-night harmony"),
            ("Acoustic Folk", "fingerpicked acoustic guitar and delicate hand percussion"),
            ("Lo-Fi", "dusty keys, soft tape texture, unhurried lo-fi beat"),
            ("Piano", "minimal solo piano with a warm, repeating motif"),
            ("Harp", "harp arpeggios, airy flute, soft orchestral bloom"),
            ("Chillwave", "sun-faded synths and slow, featherlight electronic drums"),
            ("Dub Ambient", "deep restrained dub bass and distant echo"),
            ("Flute Meditation", "breathy flute, drones, and subtle natural percussion"),
            ("Chamber Pop", "small strings, celesta, and restrained pop harmony"),
            ("Slow Soul", "silky electric piano and gentle soul pocket"),
            ("Island Acoustic", "ukulele, soft marimba, and an ocean-breeze rhythm"),
            ("Minimal Electronica", "rounded plucks and a calm minimal pulse"),
        ),
    ),
    TierProfile(
        "relaxing",
        "Relaxing",
        "78–104 BPM",
        "easygoing, warm, lightly propulsive, and pleasant without demanding attention",
        (
            ("Soft Rock", "clean guitar, round bass, and restrained live drums"),
            ("City Pop", "glossy electric piano, clean guitar, and relaxed city-pop groove"),
            ("Downtempo", "deep mellow beat, soft synth chords, and spacious production"),
            ("Smooth Jazz", "soprano sax, electric piano, and polished pocket"),
            ("Indie Folk", "acoustic strum, muted kick, and close vocal harmony"),
            ("Synthpop", "warm analog synths and a light, buoyant electronic beat"),
            ("Trip Hop", "smoky keys, vinyl texture, and a slow breakbeat"),
            ("Reggae", "laid-back one-drop drums, organ bubble, and round bass"),
            ("Blues", "clean blues guitar, brushed snare, and easy shuffle"),
            ("R&B", "silky contemporary R&B chords and a relaxed head-nod beat"),
            ("Light Funk", "clean rhythm guitar and a restrained syncopated bassline"),
            ("Acoustic Pop", "bright acoustic guitar and a soft modern pop pulse"),
            ("Lounge", "vibraphone, brushed kit, and sophisticated lounge harmony"),
            ("Yacht Rock", "smooth electric piano, clean guitar, and polished soft-rock drums"),
            ("Mellow House", "soft four-on-the-floor beat and hazy house chords"),
            ("Alt-Country", "pedal steel, acoustic guitar, and an unhurried backbeat"),
        ),
    ),
    TierProfile(
        "motivating",
        "Motivating",
        "100–128 BPM",
        "confident, forward-moving, optimistic, and built around a memorable lift",
        (
            ("Pop Rock", "driving guitars, punchy drums, and a bright anthem hook"),
            ("Indie Anthem", "rising indie guitars, toms, and a communal chorus feel"),
            ("Hip Hop", "crisp drums, bold bass, and focused motivational flow"),
            ("Electropop", "shining synth lead, tight kick, and an ascending pop hook"),
            ("Funk Rock", "syncopated bass, clipped guitar, and muscular live drums"),
            ("Power Pop", "stacked guitars, handclaps, and an immediate melodic hook"),
            ("Drumline", "snare-line precision, bass drums, and triumphant brass"),
            ("Gospel Soul", "organ, handclaps, choir responses, and uplifting soul rhythm"),
            ("Synthwave", "pulsing arpeggiator, gated drums, and heroic synth melody"),
            ("Pop Punk", "fast clean power chords, punchy snare, and upbeat momentum"),
            ("Latin Pop", "bright percussion, guitar, bass, and a confident dance groove"),
            ("Breakbeat", "crisp chopped breaks and a rising electronic motif"),
            ("Afrobeat", "interlocking guitars, buoyant percussion, and warm brass"),
            ("Garage Rock", "raw guitar riff, stomping drums, and energized vocals"),
            ("Disco", "four-on-the-floor drums, strings, and a propulsive bassline"),
            ("Melodic Rap", "modern drums, melodic vocal hook, and determined cadence"),
        ),
    ),
    TierProfile(
        "energizing",
        "Energizing",
        "126–162 BPM",
        "immediate, loud, athletic, celebratory, and impossible to mistake for background music",
        (
            ("Drum & Bass", "rapid breakbeats, elastic bass, and a bright rave lead"),
            ("Hardstyle", "hard kick, euphoric supersaws, and festival-scale builds"),
            ("Big Room", "huge kick, sharp synth stabs, and a concise arena drop"),
            ("Speed Metal", "fast twin guitars, pounding drums, and soaring vocal attack"),
            ("Punk Rock", "urgent power chords, shouted hook, and relentless live drums"),
            ("Techno", "driving kick, metallic percussion, and tense repeating synth"),
            ("Trap", "heavy 808, fast hats, brass stabs, and aggressive momentum"),
            ("Electroclash", "distorted synth bass, rigid beat, and brash vocal hook"),
            ("Ska Punk", "upstroke guitar, racing drums, and explosive horn punches"),
            ("Power Metal", "galloping drums, heroic guitars, and a towering chorus"),
            ("Rave", "breakneck piano rave, siren-like synths, and pounding kick"),
            ("Jungle", "chopped amen breaks, deep bass, and frantic dancehall energy"),
            ("Metalcore", "tight riffs, double kick, and a clean-to-shout vocal lift"),
            ("Breakcore", "hyperactive chopped drums and bright, chaotic synth melody"),
            ("Hyperpop", "maximal glossy synths, clipped drums, and pitched vocal energy"),
            ("Brass Funk", "blazing horn section, slap bass, and hard-driving funk drums"),
        ),
    ),
    TierProfile(
        "abrasive",
        "Abrasive",
        "155–220 BPM",
        "hostile, alarm-like, distorted, relentless, and engineered to defeat repeated snoozing",
        (
            ("Thrash Metal", "razor-fast palm-muted guitars, double kick, and barked vocals"),
            ("Deathcore", "downtuned breakdowns, blast beats, and extreme vocal attack"),
            ("Gabber", "distorted kick barrage, rave stab, and punishing tempo"),
            ("Industrial", "metal impacts, grinding synth bass, and machine-like drums"),
            ("Grindcore", "micro-riffs, blast beats, and chaotic shouted vocals"),
            ("Noise Rock", "feedback, dissonant guitars, and pounding live drums"),
            ("Hardcore Punk", "furious power chords, gang shouts, and breakneck drums"),
            ("Black Metal", "tremolo guitars, blast beats, and icy dissonance"),
            ("Acid Techno", "screaming resonant acid line and unbroken hard kick"),
            ("Digital Hardcore", "distorted breaks, clipped synth noise, and shouted hook"),
            ("Harsh Noise", "rhythmic static walls, piercing pulses, and sub impacts"),
            ("Powerviolence", "violent tempo switches, blown-out bass, and raw shouts"),
            ("Mathcore", "jagged odd-meter riffs, abrupt accents, and frantic drums"),
            ("Sludge Metal", "crushing slow guitar weight punctuated by violent bursts"),
            ("Terrorcore", "extreme distorted kicks, sirens, and high-speed rave abrasion"),
            ("Alarmcore", "layered warning tones, metal percussion, and distorted rhythm"),
        ),
    ),
)

TIER_TITLE_FIRST = {
    "soothing": (
        "Feather",
        "First-Light",
        "Gentle",
        "Quiet",
        "Silver",
        "Soft",
        "Still",
        "Velvet",
    ),
    "relaxing": (
        "Breezy",
        "Coastal",
        "Easy",
        "Evening",
        "Leisure",
        "Mellow",
        "Sunday",
        "Warm",
    ),
    "motivating": (
        "Brave",
        "Forward",
        "Momentum",
        "Rally",
        "Ready",
        "Rising",
        "Steady",
        "Victory",
    ),
    "energizing": (
        "Blazing",
        "Electric",
        "Full-Throttle",
        "Ignition",
        "Nitro",
        "Radiant",
        "Rocket",
        "Voltage",
    ),
    "abrasive": (
        "Anvil",
        "Blackout",
        "Buzzsaw",
        "Collision",
        "Overload",
        "Rupture",
        "Siren",
        "Wrecking",
    ),
}
TITLE_SECOND = (
    "Arrival",
    "Current",
    "Horizon",
    "Motion",
    "Signal",
    "Skyline",
    "Spark",
    "Velocity",
)
ARTIST_FIRST = (
    "Atlas",
    "Cinder",
    "Echo",
    "Juniper",
    "Lumen",
    "Nova",
    "Orchid",
    "Static",
)
ARTIST_SECOND = (
    "Assembly",
    "Collective",
    "Circuit",
    "Division",
    "Garden",
    "Method",
    "Society",
    "Works",
)

TIER_LYRICS = {
    "soothing": (
        "Easy now, the morning is near",
        "Open your eyes, the way is clear",
        "Breathe in slow, begin the day",
        "Rise when ready, light the way",
    ),
    "relaxing": (
        "Morning is moving, come along",
        "Find your rhythm, find your song",
        "Feet on the floor, steady and bright",
        "Take the day in easy stride",
    ),
    "motivating": (
        "Stand up strong, the time is now",
        "Make your move and keep your vow",
        "One clear step, then one step more",
        "Own the morning, leave the door",
    ),
    "energizing": (
        "Get up now, ignite the day",
        "Move your body, lead the way",
        "Heart awake and eyes on fire",
        "Rise and grind, climb higher",
    ),
    "abrasive": (
        "Wake up now, get out of bed",
        "No more snooze, move feet and head",
        "Stand up fast, the clock is done",
        "Rise and grind, the day has begun",
    ),
}


def build_catalog() -> tuple[dict[str, Any], ...]:
    """Return 320 unique songs, 64 songs for each ordered tier."""
    tracks: list[dict[str, Any]] = []
    for tier in TIER_PROFILES:
        for offset in range(64):
            number = offset + 1
            first_index = offset // 8
            second_index = offset % 8
            genre_name, genre_description = tier.genres[offset % len(tier.genres)]
            tracks.append(
                {
                    "number": number,
                    "id": f"{tier.identifier}_{number:03d}",
                    "intensityTier": tier.identifier,
                    "intensityName": tier.display_name,
                    "displayName": (
                        f"{TIER_TITLE_FIRST[tier.identifier][first_index]} "
                        f"{TITLE_SECOND[second_index]}"
                    ),
                    "filename": f"{tier.display_name}{number:03d}",
                    "artistName": (
                        f"{ARTIST_FIRST[second_index]} {ARTIST_SECOND[first_index]}"
                    ),
                    "genreName": genre_name,
                    "genreDescription": genre_description,
                    "bpmRange": tier.bpm_range,
                    "energyDirection": tier.energy_direction,
                    "performedLyrics": list(TIER_LYRICS[tier.identifier]),
                    "defaultSelected": True,
                }
            )
    validate_catalog(tracks)
    return tuple(tracks)


def validate_catalog(catalog: list[dict[str, Any]]) -> None:
    """Require complete, unique metadata and exactly 64 songs per tier."""
    if len(catalog) != 320:
        raise RuntimeError(f"Expected 320 tracks, found {len(catalog)}")
    for key in ("id", "filename"):
        values = [str(track[key]) for track in catalog]
        if len(values) != len(set(values)):
            raise RuntimeError(f"Catalog contains duplicate {key} values")
    for tier in TIER_PROFILES:
        tier_tracks = [
            track for track in catalog if track["intensityTier"] == tier.identifier
        ]
        if len(tier_tracks) != 64:
            raise RuntimeError(
                f"Expected 64 {tier.identifier} tracks, found {len(tier_tracks)}"
            )
        identities = {
            (track["displayName"], track["artistName"]) for track in tier_tracks
        }
        if len(identities) != 64:
            raise RuntimeError(f"{tier.display_name} contains duplicate song identities")
    if len({(track["displayName"], track["artistName"]) for track in catalog}) != 320:
        raise RuntimeError("Catalog contains duplicate title and artist identities")


CATALOG = build_catalog()
