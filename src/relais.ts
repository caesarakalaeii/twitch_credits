import { Gpio, Direction, Edge, Options } from 'onoff'
import { wait } from './wait'

export type PinConfig = {
  gpio: number,
  direction: Direction,
  edge?: Edge
  options: Options
}

export type PinName = 'relais'

export type RelaisConfig = {
  pin: {[U in PinName]: PinConfig}
}

export class Relais {
  pin: {[U in PinName]?: Gpio} = {}

  constructor (private config: RelaisConfig) {
    for (const [k, v] of Object.entries(this.config.pin)) {
      this.pin[k] = new Gpio(v.gpio, v.direction, v.edge, v.options)
    }
  }

  async on (name: PinName) {
    await this.pin[name]?.write(Gpio.HIGH)
  }

  async off (name: PinName) {
    await this.pin[name]?.write(Gpio.LOW)
  }

  /**
   * sets the given port on for a given time, then turns it off
   * @param name name of the gpio pin
   * @param time time in milliseconds
   */
  async onFor (name: PinName, time: number) {
    this.on(name)
      .then(() => wait(time))
      .then(() => this.off(name))
  }
}
