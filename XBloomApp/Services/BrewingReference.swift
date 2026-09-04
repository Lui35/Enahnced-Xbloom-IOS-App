import Foundation

/// The brewing-science context the recipe prompts reason from, when
/// `GeminiService.usesBrewingReference` is on.
///
/// Deliberately not a copy of the published pour-over literature. The model
/// already knows Kasuya, Hoffmann and Rao far better than a summary could
/// restate them, so the famous methods appear here only as the levers they
/// contribute. What is kept is the part no training data can supply: what this
/// machine's controls physically mean.
///
/// Grind is the reason this file exists. The prompt used to say only
/// "grind must be 31-55", a range with no meaning attached, leaving the single
/// largest lever on extraction as the least specified number in the request.
///
/// Grind guidance is expressed as shifts from 50 on purpose. Nothing in this
/// repo or the machine documentation says what the dial means in microns, and
/// the only evidence available is that `Recipe` defaults to 50 and all three
/// `RecipeLibrary` recipes sit at 48-55. Absolute bands invented around that
/// evidence would read as calibration the machine has never actually been
/// tested against; relative shifts encode only what is known.
enum BrewingReference {
    static let text = """
    # Machine and brewing reference

    Reason from this. It is context for judgment, not a table to look values up
    in. Machine limits stated in the task instructions always override it.

    ## 1. What these controls physically do

    This machine pours: volume, temperature, flow rate, pattern, and a pause
    after each pour. That is all it has.

    - It cannot stir, swirl, pour from height, disperse, or hold immersion. The
      only agitation available is `agitationBefore` and `agitationAfter` on each
      pour. Translate technique into those: "swirl after the bloom" is
      `agitationAfter` on the bloom pour; "never agitate" is both flags false
      throughout, leaving pattern and flow to do the work.
    - It cannot see the bed, so it cannot wait for a surface to run dry. Every
      interval is a fixed pause chosen in advance.

    **Grind.** An xBloom dial position, not microns. Lower is finer. 50 is the
    reference point: it is the app's default and the middle of the shipped
    recipes. Move from 50 rather than picking from the range.

    | Move | Amount | When |
    |---|---|---|
    | Finer | 4-8 | dense, high-grown, light-roast, washed; a stale bean; under-extraction |
    | Finer | 2-4 | mildly under-extracted, or a clean cup that lacks sweetness |
    | Stay at 50 | — | medium roast, blends, no strong signal either way |
    | Coarser | 2-4 | natural or honey process; a very fresh bean still degassing hard |
    | Coarser | 4-6 | dark roast, low elevation, highly soluble; over-extraction |

    Stack these with judgment, not arithmetic: a dark natural is one move
    coarser, not two. Stay well inside 31-55 unless the bean genuinely demands
    an edge.

    **Flow rate**, 3.0-3.5 ml/s. 3.0 is gentler and gives more contact time —
    fine grinds, light roasts. 3.5 is faster with less contact, which keeps
    coarse grinds and dark roasts from over-extracting.

    **Pattern.** Center wets a narrow column and agitates least, which is what a
    bloom wants. Circular saturates evenly and is the default for main pours.
    Spiral covers the most surface and agitates most, for a pour that needs to
    move the bed.

    **Grinder RPM**, 60-120. Lower generates less heat and preserves delicate
    aromatics: 60-75 for light roasts and anything floral, 75-90 as the
    all-rounder, 90-120 for medium and dark where there is less to lose.

    **Temperature**, 80-96°C. Light roasts are dense and resist water, so they
    need the top of the range; dark roasts are porous and give everything up
    early, so heat only fetches bitterness. Most extraction happens in the first
    pours while the slurry is hottest. Keeping the temperature high throughout
    suits light roasts; dropping the last pour or two by 3-5°C measurably
    reduces astringency on dark ones.

    ## 2. Bloom

    Volume against dose: 2x is standard, 3x for a very fresh bean degassing
    hard or for a long bloom, 4x when the bloom must saturate everything without
    agitation, 1.5x for a stale bean with little CO2 left.

    Rest by roast: light 45-60 s, medium 30-45 s, dark 20-30 s. Dense beans hold
    more gas and release it slower.

    By freshness: at 1-3 days post-roast the bloom is explosive and extraction is
    hard to keep even, so rest longer and agitate less. 4-14 days is the ideal
    window. Past 28 days the bloom is weak or absent, so use less bloom water, a
    shorter rest, and a finer grind to make up for how easily a stale bean gives
    up its solubles.

    Until the CO2 is gone it forms a gas barrier that repels water and makes
    extraction uneven, which is the entire reason the bloom exists.

    ## 3. Pour architecture

    Each pour is an agitation event in itself, whatever the flags say. More
    pours means more agitation, longer contact, higher extraction and more body
    — and more risk of fines clogging the bed. Fewer, larger pours mean a
    faster, cleaner brew at a lower extraction.

    | Pours | Body | Clarity | Suits |
    |---|---|---|---|
    | 1 | low-medium | high | clean and bright |
    | 2 | medium | high | everyday; a long bloom then one main pour |
    | 3 | medium | medium-high | the most versatile |
    | 4-5 | medium-high | medium | controlled, staged flavor |
    | 6-8 | high | lower | full body, micro-pulse |

    Front-loading — 60% or more of the water by the end of the first main pour —
    raises early extraction and gives brightness and complexity. Distributing
    evenly is the most repeatable and the most balanced. Back-loading is
    uncommon and turns muddy once the bed has collapsed.

    Two levers worth knowing. Within the opening 40% of the water, a larger
    first pour than second pushes acidity and brightness, a smaller one pushes
    sweetness. Within the closing 60%, splitting into more pours builds body;
    keeping it as one builds clarity.

    ## 4. Reading the bean

    **Process.** Naturals are less dense, extract faster, and shed more fines
    when ground; fewer pours and little agitation keep those fines in place and
    astringency out. Washed coffees have uniform structure and take a finer
    grind and firmer handling without turning muddy. Honey sits between.

    **Elevation.** Below 1200 m: low density, extracts easily, coarser and
    cooler. Above 1600 m: dense, resists extraction, finer and hotter. Dense
    beans also fracture more uniformly, so they throw fewer fines.

    **Age.** Rest before use scales with roast — light 7-14 days, medium 5-10,
    dark 2-5. Peak is roughly 7-21 days; after that, grind finer and bloom
    shorter as it fades.

    **Blends** have already been balanced by the roaster. Use middle-ground
    parameters and avoid extremes of any one variable. A single origin can be
    pushed toward its own strengths.

    ## 5. Diagnosing a cup

    Sour, thin or salty is under-extracted: grind finer, raise the temperature,
    add agitation, lengthen the bloom, slow the flow.

    Bitter, astringent or drying is over-extracted: grind coarser, lower the
    temperature, cut agitation, shorten the bloom, speed the flow.

    Sweet, balanced and clean-finishing is the target. Acids extract first,
    sugars second, bitter compounds last; the craft is to extract through the
    sweetness and stop before the bitterness.

    Levers ranked by how much they actually move the cup: grind size, then
    temperature, then pour architecture, then agitation, then flow rate. Prefer
    changing the top of that list.

    ## 6. Fines and channeling

    Fines are the sub-100-micron particles made during grinding. Water carries
    them onto the filter, where they clog it, slow the drawdown, and push water
    into channels — over-extracting part of the bed while leaving the rest raw.
    Agitation accelerates this. That is the central tension: agitation makes
    extraction more even and clogging more likely. The two stable answers are a
    fine grind with almost no agitation, or a coarse grind with plenty. Coarse
    grinds tolerate agitation; fine grinds do not.
    """
}
