import EventEmitter from 'events';
import { wait } from './wait';

export type TaserConfig = {
  delay: number
  power: {
    min: number
    max: number
    start: number
  }
}

export class Taser {
  protected power: number = 0
  protected event: EventEmitter = new EventEmitter()

  on (eventName: 'dec', listener: (power: number) => any): this
  on (eventName: 'inc', listener: (power: number) => any): this
  on (eventName: string, listener: (...args: any) => any): this {
    this.event.on(eventName, listener)
    return this
  }

  constructor (protected config: TaserConfig) {
    this.power = config.power.start
  }

  async increasePower () {
    if (this.power < this.config.power.max) { 
      this.power++
      this.event.emit('dec', this.power)  //taser uses safety feature to prevent accidental power increase, power down needed to circumvent
      await wait(this.config.delay)
      this.event.emit('inc', this.power)
      await wait(this.config.delay)
      this.event.emit('inc', this.power)
    }
  }

  async decreasePower() {
    if (this.power > this.config.power.min) {
      this.power--
      this.event.emit('dec', this.power)
    }
  }
}
