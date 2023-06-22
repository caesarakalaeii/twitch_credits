type QueueItem = () => Promise<any>

export class Queue {
  private stack: QueueItem[] = []

  private run (item: QueueItem) {
    item()
      .catch(err => console.error(err))
      .finally(() => this.next())
  }

  private next () {
    if (this.stack.length > 0) {
      const item = this.stack.shift()
      if (item) this.run(item)
    }
  }

  add (item: QueueItem) {
    if (this.stack.length > 0) {
      this.stack.push(item)
    } else {
      this.run(item)
    }
  }
}
