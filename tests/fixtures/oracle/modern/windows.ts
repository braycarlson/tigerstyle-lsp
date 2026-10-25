const broken: string = `one
two`;

export function total(values: number[]): number {
   
    // AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA

    let running = 0;

    for (const value of values) {
        running = running + value;
    }

    return running + broken.length;
}
