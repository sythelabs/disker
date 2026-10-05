// Run with a Disker app binding from cua_repl.
interface SizeProportionApp {
    getAXState(options: { emit: boolean; disableDiffing: boolean }): Promise<string>;
    scroll(target: number, direction: "down" | "up", distance: number): Promise<void>;
}

export async function verifySizeProportionScroll(app: SizeProportionApp): Promise<number> {
    const initial: string = await app.getAXState({ emit: false, disableDiffing: true });
    const firstBar: number = initial.indexOf("Share of parent folder");
    if (firstBar < 0) throw new Error("Disker file table size bars were not found");
    const scrollAreas: RegExpMatchArray[] = Array.from(initial.slice(0, firstBar).matchAll(/^\s*([0-9]+) scroll area/gm));
    const scrollArea: RegExpMatchArray | undefined = scrollAreas.pop();
    if (scrollArea === undefined) throw new Error("Disker file table scroll area was not found");
    const target: number = Number(scrollArea[1]);
    await app.scroll(target, "down", 2);
    await app.scroll(target, "up", 2);
    const state: string = await app.getAXState({ emit: false, disableDiffing: true });
    const bars: RegExpMatchArray[] = Array.from(state.matchAll(/^\s*([0-9]+(?:\.[0-9]+)?(?:e[-+]?[0-9]+)?)\s*\n\s*([0-9]+(?:\.[0-9]+)?)%/gm));
    if (bars.length === 0) throw new Error("No visible size bars were checked");
    for (const bar of bars) {
        const actual: number = Number(bar[1]) * 100;
        const expected: number = Number(bar[2]);
        if (Math.abs(actual - expected) > 0.051) {
            throw new Error("Size bar disagrees with row percentage: " + actual + "% versus " + expected + "%");
        }
    }
    return bars.length;
}
