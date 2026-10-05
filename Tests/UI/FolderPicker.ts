interface FolderPickerApp {
    getAXState(options: { emit: boolean; disableDiffing: boolean }): Promise<string>;
    click(target: number): Promise<void>;
}

export async function verifyFolderPicker(app: FolderPickerApp): Promise<void> {
    const initial: string = await app.getAXState({ emit: false, disableDiffing: true });
    const choose: RegExpMatchArray | null = initial.match(/^\s*([0-9]+) button Description: Choose Folder/m);
    if (choose === null) throw new Error("Choose Folder action was not found");
    await app.click(Number(choose[1]));
    const picker: string = await app.getAXState({ emit: false, disableDiffing: true });
    if (!picker.includes("ID: open-panel")) throw new Error("Choose Folder did not present the native folder picker");
    const cancel: RegExpMatchArray | null = picker.match(/^\s*([0-9]+) button Cancel, ID: CancelButton/m);
    if (cancel === null) throw new Error("Native folder picker Cancel action was not found");
    await app.click(Number(cancel[1]));
    const closed: string = await app.getAXState({ emit: false, disableDiffing: true });
    if (closed.includes("ID: open-panel")) throw new Error("Native folder picker did not close");
}
