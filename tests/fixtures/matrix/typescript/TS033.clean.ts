interface Range {
    start: number;
    end: number;
}

function span(range: Range): number {
    return range.end - range.start;
}
