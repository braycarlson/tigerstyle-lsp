const broken = `one
two`;

function total(values) {
   
    // AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA

    let running = 0;

    for (const value of values) {
        running = running + value;
    }

    return running + broken.length;
}
