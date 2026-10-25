package fixture

import "core:container/queue"

run :: proc() {
    held: queue.Queue(int)
    queue.init(&held)
}
