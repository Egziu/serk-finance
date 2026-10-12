// Independent Node implementation used ONLY to provision synthetic browser fixtures.
import {createHmac,randomBytes} from 'node:crypto';
const alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
export function fixtureSecret(){let bits='';for(const byte of randomBytes(20))bits+=byte.toString(2).padStart(8,'0');return bits.match(/.{5}/g).map(b=>alphabet[parseInt(b,2)]).join('')}
export function fixtureCode(secret,time=Date.now()){let bits='';for(const c of secret)bits+=alphabet.indexOf(c).toString(2).padStart(5,'0');const key=Buffer.from(bits.match(/.{8}/g).map(b=>parseInt(b,2)));const counter=Buffer.alloc(8);counter.writeBigUInt64BE(BigInt(Math.floor(time/30000)));const h=createHmac('sha1',key).update(counter).digest();return ((h.readUInt32BE(h[19]&15)&0x7fffffff)%1000000).toString().padStart(6,'0')}
