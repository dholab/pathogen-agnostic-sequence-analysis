#!/usr/bin/env nextflow

nextflow.enable.dsl = 2



// WORKFLOW SPECIFICATION
// --------------------------------------------------------------- //
workflow {
	
	
	// input channels
	ch_reads = Channel
        .fromPath( params.samplesheet )
        .splitCsv( header: true )
        .map { row -> tuple( row.raw_read_label, row.sample_id, row.parent_dir ) }
    
    ch_ref_seqs = Channel
        .fromPath( params.virus_ref )
	
	// Workflow steps 
    FIND_AND_MERGE_FASTQS (
        ch_reads
    )

    SAMPLE_QC (
        FIND_AND_MERGE_FASTQS.out
    )

    MAP_TO_REFSEQS (
        SAMPLE_QC.out,
        ch_ref_seqs
    )
	
	
}
// --------------------------------------------------------------- //



// DERIVATIVE PARAMETER SPECIFICATION
// --------------------------------------------------------------- //
// Additional parameters that are derived from parameters set in nextflow.config
params.merged_fastqs = params.results + "/1_merged_fastqs"
params.filtered_fastqs = params.results + "/2_filtered_fastqs"
params.bams = params.results + "/3_alignment_maps"
// --------------------------------------------------------------- //




// PROCESS SPECIFICATION 
// --------------------------------------------------------------- //

process FIND_AND_MERGE_FASTQS {
	
	/*
    Here we determine if the read labels are SRA accessions or 
    local file names. If they are SRA accessions, they will be 
    downloaded and merged automatically from SRA servers. If 
    they are local, they will be located and merged.
    */ 
	
	tag "${sample_id}"
    publishDir params.merged_fastqs, mode: 'symlink'
	
	input:
	tuple val(label), val(sample_id), path(parent_dir)
	
	output:
	tuple path("*.fastq.gz"), val(sample_id)
	
	script:
    if ( label.startsWith("SRR") )
        """
        prefetch ${label}
	    fasterq-dump ${label}/${label}.sra \
	    --concatenate-reads --skip-technical --quiet && \
	    gzip ${label}.sra.fastq
	    mv ${label}.sra.fastq.gz ${sample_id}.fastq.gz
	    rm -rf ${label}/
	    rm -rf fasterq.tmp.*
        """
    else
        """
        cat ${parent_dir}/${label}*.fastq.gz > ${sample_id}.fastq.gz
        """
}


process SAMPLE_QC {
	
	/*
    Here we run some trimming and quality filtering with the bbmap
    script `reformat.sh` for PacBio or Illumina reads, or cutadapt
    for ONT reads.
    */
	
	tag "${sample_id}"
    publishDir params.filtered_fastqs, mode: 'copy'
	
	input:
	tuple path(fastq), val(sample_id)
	
	output:
	tuple path("*.fastq.gz"), val(sample_id)
	
	script:
    if ( params.ont == true )
        """
        cutadapt -a ${params.adapter_seq} \
        -m 200 -q 30 --trim-n \
        -o ${sample_id}_filtered.fastq.gz \
        ${fastq}
        """
    else if( params.pacbio == true )
        """
        reformat.sh in=${fastq} \
        out=${sample_id}_filtered.fastq.gz \
        forcetrimleft=30 forcetrimright2=30 \
        mincalledquality=7 minlength=200 qin=33
        """
    else 
        """
        reformat.sh in=${fastq} \
        out=${sample_id}_filtered.fastq.gz \
        forcetrimleft=30 forcetrimright2=30 \
        mincalledquality=7 minlength=200 qin=33
        """

}


process MAP_TO_REFSEQS {
	
	/* 
    This process maps each sample ID's reads to a reference FASTA 
    of 835 human viruses. The resulting BAMs will serve as "hits"
    for which viruses were present in a given air sample.
    */
	
	tag "${sample_id}"
    publishDir params.bams, mode: 'copy'
	
	input:
	tuple path(fastq), val(sample_id)
    each path(refseq)
	
	output:
	tuple path("*.bam*"), val(sample_id)
	
	script:
	"""
    minimap2 \
    -ax map-ont \
    ${refseq} \
    ${fastq} \
    --eqx \
    | reformat.sh \
    in=stdin.sam \
    ref=${refseq} \
    out=${sample_id}_filtered.bam \
    mappedonly=t
	"""
}


// --------------------------------------------------------------- //