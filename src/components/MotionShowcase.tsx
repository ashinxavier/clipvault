import { LazyMotion, m, useReducedMotion } from "framer-motion";

const loadFeatures = () =>
  import("./motion-features").then(({ default: features }) => features);

type MotionShowcaseProps = {
  src: string;
  alt: string;
};

export default function MotionShowcase({ src, alt }: MotionShowcaseProps) {
  const reduceMotion = useReducedMotion();

  return (
    <LazyMotion features={loadFeatures} strict>
      <m.figure
        className="relative mx-auto w-full max-w-[620px]"
        initial={reduceMotion ? false : { y: 16 }}
        whileInView={reduceMotion ? undefined : { y: 0 }}
        viewport={{ once: true, amount: 0.18 }}
        transition={{ duration: 0.72, ease: "easeOut" }}
      >
        <div className="absolute -inset-5 -z-10 rounded-[2.5rem] bg-[radial-gradient(ellipse_at_45%_40%,rgba(91,139,255,0.24),transparent_70%)] blur-2xl sm:-inset-10" />
        <div className="overflow-hidden rounded-[1.6rem] border border-white/80 bg-white/80 p-1.5 shadow-[0_36px_90px_rgba(23,31,55,0.2)] sm:rounded-[2rem] sm:p-2">
          <img
            src={src}
            alt={alt}
            width="440"
            height="600"
            fetchPriority="high"
            decoding="async"
            className="h-auto w-full rounded-[1.2rem] border border-black/[0.05] sm:rounded-[1.5rem]"
          />
        </div>
      </m.figure>
    </LazyMotion>
  );
}
